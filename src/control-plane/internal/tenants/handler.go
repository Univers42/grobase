package tenants

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/identity"
	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// Mount registers tenant routes onto the shared mux.
//
// Auth model:
//   - Service-token routes: control plane only (admin CRUD + key verify).
//   - JWT-authenticated route (/v1/tenants/me/bootstrap): the holder of a
//     valid GoTrue JWT can bootstrap *their own* tenant — used by the
//     signup -> first request flow.
//   - Tenant-scoped GETs accept X-Baas-Tenant-Id for tenant-self lookups.
//
// jwtVerifier may be nil; in that case /v1/tenants/me/bootstrap returns 501.
//
// reconciler may be nil; in that case POST /v1/provision falls back to the
// legacy svc.Provision path (backward-compat). When set, /v1/provision routes
// through the declarative reconciler. Route ownership stays HERE (one mux
// registration) — see provision.Mount for the standalone seam.
//
// The TENANT SELF-SERVICE surface (/v1/tenants/me, /me/usage, /me/keys[/{id}],
// PATCH /me — Track-B B4a) lives in selfserve.go and is mounted SEPARATELY via
// MountSelfServe, gated on TENANT_SELFSERVE_ENABLED (off by default = no routes
// = byte-parity). It is mounted from main.go alongside metering.Mount rather
// than here, so the env flag + manifest load stay at the composition root; the
// static "me*" literals out-rank the {id} wildcards registered below, so the two
// route sets never conflict.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string, jwtVerifier *JWTVerifier, reconciler *provision.Reconciler) {
	rt := &routes{svc: svc, serviceToken: serviceToken, jwt: jwtVerifier, reconciler: reconciler}

	mux.HandleFunc("POST /v1/tenants", rt.requireServiceToken(rt.create))
	mux.HandleFunc("GET /v1/tenants", rt.requireServiceToken(rt.list))
	mux.HandleFunc("GET /v1/tenants/{id}", rt.findOne)
	mux.HandleFunc("PATCH /v1/tenants/{id}", rt.requireServiceToken(rt.update))
	mux.HandleFunc("DELETE /v1/tenants/{id}", rt.requireServiceToken(rt.remove))

	mux.HandleFunc("POST /v1/tenants/{id}/bootstrap", rt.requireServiceToken(rt.bootstrap))

	// Declarative reconcile: tenant + key + role + data mounts in one call.
	mux.HandleFunc("POST /v1/provision", rt.requireServiceToken(rt.provision))

	// Self-bootstrap by JWT: the signed-in user provisions their own tenant.
	// Static "me" path is matched before the {id} parameterised one because
	// net/http mux gives precedence to the most-specific pattern.
	mux.HandleFunc("POST /v1/tenants/me/bootstrap", rt.selfBootstrap)

	mux.HandleFunc("POST /v1/tenants/{id}/keys", rt.requireServiceToken(rt.issueKey))
	mux.HandleFunc("GET /v1/tenants/{id}/keys", rt.requireServiceToken(rt.listKeys))
	mux.HandleFunc("DELETE /v1/tenants/{id}/keys/{keyId}", rt.requireServiceToken(rt.revokeKey))

	mux.HandleFunc("POST /v1/keys/verify", rt.requireServiceToken(rt.verifyKey))
}

type routes struct {
	svc          *Service
	serviceToken string
	jwt          *JWTVerifier
	reconciler   *provision.Reconciler
}

const msgInvalidJSON = "invalid JSON"

func (rt *routes) requireServiceToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
			httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		next(w, r)
	}
}

// tokenOrSelf authorises read of a tenant by either a service token or by a
// tenant-self assertion via X-Baas-Tenant-Id (a tenant fetching its own row).
//
// The self arm goes through identity.TenantSelfMatch: the raw header must equal
// id, AND — when TENANT_HEADER_IDENTITY_HMAC is set — a valid X-Baas-Identity-Auth
// signature over the asserted identity is required, so a FORGED header cannot
// authorize a cross-tenant read on its own. With the flag OFF (default) this is
// byte-identical to the previous `header == id` check (parity). The service-token
// arm (admin) never relies on the header. The deeper fix — deriving the tenant
// from a verified credential, as selfServe.selfAuth does (no path {id}) — needs
// each caller to forward a credential this internal {id} route does not receive
// today; the HMAC envelope closes the forge vector without that wider change.
func (rt *routes) tokenOrSelf(w http.ResponseWriter, r *http.Request, id string) bool {
	if serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if identity.TenantSelfMatch(r, rt.serviceToken, id) {
		return true
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token or matching tenant header required")
	return false
}

func (rt *routes) handleLookup(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "tenant not found")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
