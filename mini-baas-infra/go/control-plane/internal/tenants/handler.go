package tenants

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
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
		if !shared.VerifyServiceRequest(r, rt.serviceToken) {
			shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		next(w, r)
	}
}

func (rt *routes) create(w http.ResponseWriter, r *http.Request) {
	var req CreateTenantRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if err := req.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	t, err := rt.svc.Create(r.Context(), req)
	switch {
	case errors.Is(err, ErrConflict):
		shared.WriteError(w, http.StatusConflict, "conflict", "tenant already exists")
	case err != nil:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		shared.WriteJSON(w, http.StatusCreated, t)
	}
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.List(r.Context())
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) findOne(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, id) {
		return
	}
	t, err := rt.svc.FindOne(r.Context(), id)
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, t)
}

func (rt *routes) update(w http.ResponseWriter, r *http.Request) {
	var req UpdateTenantRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	t, err := rt.svc.Update(r.Context(), r.PathValue("id"), req)
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, t)
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	if rt.handleLookup(w, rt.svc.SoftDelete(r.Context(), r.PathValue("id"))) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (rt *routes) bootstrap(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req BootstrapRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	name := id
	if v := r.URL.Query().Get("name"); v != "" {
		name = v
	}
	out, err := rt.svc.Bootstrap(r.Context(), id, name, req)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, out)
}

func (rt *routes) provision(w http.ResponseWriter, r *http.Request) {
	// Cap the body before decoding (DoS guard): the provision payload carries
	// unbounded arrays (mounts/roles/keys), so reject an oversized request before
	// it can exhaust memory. Same centralized cap as the standalone seam.
	r.Body = http.MaxBytesReader(w, r.Body, provision.MaxRequestBodyBytes)
	var req ProvisionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if err := req.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}

	// Preferred path: route the legacy declarative request through the new
	// reconcile brain (Compile maps the old shape onto a typed StackSpec).
	if rt.reconciler != nil {
		out, err := rt.reconciler.Reconcile(r.Context(), req.Compile())
		switch {
		case errors.Is(err, provision.ErrBusy):
			shared.WriteError(w, http.StatusConflict, "conflict", err.Error())
		case err != nil:
			shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		default:
			shared.WriteJSON(w, provision.HTTPStatus(out.Outcome, out.APIKey != nil), out)
		}
		return
	}

	// Fallback (no reconciler wired): the original one-shot Provision path.
	out, err := rt.svc.Provision(r.Context(), req)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, out)
}

// selfBootstrap is the GoTrue-JWT-authenticated counterpart to /bootstrap.
//
// Closes the signup -> first request loop: the just-signed-up user presents
// their JWT, we resolve their user id from the `sub` claim, find the tenant
// auto-provisioned by migration 033's trigger (or create one defensively),
// and issue a first API key. The cleartext key is returned ONCE; subsequent
// calls return `key_reuse: true` without exposing a new secret.
//
// Optional JSON body: { "default_key_name": "primary" }. Defaults to "default".
func (rt *routes) selfBootstrap(w http.ResponseWriter, r *http.Request) {
	if rt.jwt == nil {
		shared.WriteError(w, http.StatusNotImplemented, "not_implemented",
			"tenant-control is not configured with GOTRUE_JWT_SECRET")
		return
	}
	auth := r.Header.Get("Authorization")
	if auth == "" {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "Authorization: Bearer <jwt> required")
		return
	}
	identity, err := rt.jwt.Verify(auth)
	if err != nil {
		shared.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
		return
	}

	keyName := ""
	if r.ContentLength > 0 {
		var body struct {
			DefaultKeyName string `json:"default_key_name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
			return
		}
		keyName = body.DefaultKeyName
	}

	out, err := rt.svc.BootstrapForUser(r.Context(), identity.UserID, identity.Email, keyName)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}

	status := http.StatusOK
	if out.Created || out.APIKey != nil {
		status = http.StatusCreated
	}
	shared.WriteJSON(w, status, out)
}

func (rt *routes) issueKey(w http.ResponseWriter, r *http.Request) {
	var req IssueKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	out, err := rt.svc.IssueKey(r.Context(), r.PathValue("id"), req)
	if err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, out)
}

func (rt *routes) listKeys(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListKeys(r.Context(), r.PathValue("id"))
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) revokeKey(w http.ResponseWriter, r *http.Request) {
	if rt.handleLookup(w, rt.svc.RevokeKey(r.Context(), r.PathValue("id"), r.PathValue("keyId"))) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}

func (rt *routes) verifyKey(w http.ResponseWriter, r *http.Request) {
	var req VerifyKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	out, err := rt.svc.VerifyKey(r.Context(), req.Key)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	status := http.StatusOK
	if !out.Valid {
		status = http.StatusUnauthorized
	}
	shared.WriteJSON(w, status, out)
}

// tokenOrSelf authorises read of a tenant by either a service token or by a
// matching X-Baas-Tenant-Id header (a tenant fetching its own row).
func (rt *routes) tokenOrSelf(w http.ResponseWriter, r *http.Request, id string) bool {
	if shared.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if r.Header.Get("X-Baas-Tenant-Id") == id || r.Header.Get("X-Tenant-Id") == id {
		return true
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token or matching tenant header required")
	return false
}

func (rt *routes) handleLookup(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "tenant not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
