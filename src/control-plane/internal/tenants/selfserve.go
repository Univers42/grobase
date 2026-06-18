package tenants

import (
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
)

// selfServe holds the dependencies for the tenant self-service API (B4a).
//
// A caller authenticated AS a tenant — via a tenant API key (X-API-Key /
// `Authorization: Bearer mbk_...`) OR a GoTrue user JWT — operates on its OWN
// tenant through `/v1/tenants/me*`. There is NO path id, so cross-tenant access
// is impossible by construction: every handler resolves the caller's tenant id
// from the credential and binds it into the service call. The slug a key/JWT
// resolves to is the ONLY tenant a request can ever touch.
//
// FLAG-GATED OFF = PARITY: MountSelfServe is called only when
// TENANT_SELFSERVE_ENABLED is truthy. When OFF, none of the /me routes are
// registered, so a request to them 404s exactly as it does today (byte-parity
// with the live baseline — no new path exists).
type selfServe struct {
	svc      *Service
	jwt      *JWTVerifier
	manifest *packages.Manifest
	// billing reports whether BILLING_ENABLED is set; when true a plan PATCH also
	// updates public.tenant_billing.plan. The live Stripe subscription change is a
	// SEPARATE flag-gated step (see PATCH handler TODO) — NOT in B4a.
	billing bool
}

// MountSelfServe registers the six self-service routes onto the shared mux. It is
// the caller's responsibility to invoke this ONLY when TENANT_SELFSERVE_ENABLED
// is truthy (main.go gates it) — when the flag is OFF this function is never
// called and the /me routes do not exist (404 = parity).
//
// jwt may be nil (no GOTRUE_JWT_SECRET): JWT-bearer self-auth then fails 401,
// but API-key self-auth still works. The static "me" paths are registered
// alongside the existing "me/bootstrap" route; net/http's most-specific-pattern
// precedence keeps them disjoint from the parameterised {id} routes.
// SelfServeDeps groups the dependencies MountSelfServe wires into the /me route
// handlers (svc, optional JWT verifier, package manifest, billing flag).
type SelfServeDeps struct {
	Svc      *Service
	JWT      *JWTVerifier
	Manifest *packages.Manifest
	Billing  bool
}

func MountSelfServe(mux *http.ServeMux, d SelfServeDeps) {
	ss := &selfServe{svc: d.Svc, jwt: d.JWT, manifest: d.Manifest, billing: d.Billing}

	mux.HandleFunc("GET /v1/tenants/me", ss.me)
	mux.HandleFunc("GET /v1/tenants/me/usage", ss.meUsage)
	mux.HandleFunc("GET /v1/tenants/me/keys", ss.listKeys)
	mux.HandleFunc("POST /v1/tenants/me/keys", ss.issueKey)
	mux.HandleFunc("DELETE /v1/tenants/me/keys/{keyId}", ss.revokeKey)
	mux.HandleFunc("PATCH /v1/tenants/me", ss.patch)
}

// selfAuth resolves the caller's OWN tenant from its credential. It tries, in
// order:
//  1. a tenant API key — X-API-Key, or `Authorization: Bearer mbk_...` —
//     verified via Service.VerifyKey, yielding {TenantID (slug), Scopes}.
//  2. a GoTrue user JWT — `Authorization: Bearer <jwt>` — verified via
//     JWTVerifier.Verify, then owner_user_id → tenant resolved. A JWT grants
//     full self-management scopes (the user owns the tenant), so writes are
//     allowed; an API key is constrained by its own scopes.
//
// On any failure it writes a 401 and returns ok=false. The returned tenantID is
// the canonical SLUG (what every downstream Service method keys on).
func (ss *selfServe) selfAuth(w http.ResponseWriter, r *http.Request) (tenantID string, scopes []string, ok bool) {
	if raw := httpx.APIKeyFromRequest(r); raw != "" {
		return ss.authByAPIKey(w, r, raw)
	}
	if auth := strings.TrimSpace(r.Header.Get("Authorization")); auth != "" {
		return ss.authByJWT(w, r, auth)
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"X-API-Key, Authorization: Bearer <api-key>, or Authorization: Bearer <jwt> required")
	return "", nil, false
}

// authByAPIKey resolves the caller's tenant from a verified tenant API key.
func (ss *selfServe) authByAPIKey(w http.ResponseWriter, r *http.Request, raw string) (string, []string, bool) {
	out, err := ss.svc.VerifyKey(r.Context(), raw)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", nil, false
	}
	if !out.Valid {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_key", "API key is not valid")
		return "", nil, false
	}
	return out.TenantID, out.Scopes, true
}

// authByJWT resolves the caller's tenant from a GoTrue user JWT (RESOLVE-ONLY).
//
// A /me request must never have a write side effect: tenant creation is the
// explicit job of POST /v1/tenants/me/bootstrap, so a JWT for a user who owns no
// tenant yet gets a 404 here (not a silently-provisioned tenant). A
// JWT-authenticated user is the tenant OWNER, so once resolved it gets full
// self-management scopes.
func (ss *selfServe) authByJWT(w http.ResponseWriter, r *http.Request, auth string) (string, []string, bool) {
	if ss.jwt == nil {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"JWT self-auth not configured (no GOTRUE_JWT_SECRET); use an API key")
		return "", nil, false
	}
	identity, err := ss.jwt.Verify(auth)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
		return "", nil, false
	}
	t, err := ss.svc.findForUser(r.Context(), identity.UserID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			httpx.WriteError(w, http.StatusNotFound, "no_tenant",
				"no tenant for this user yet — POST /v1/tenants/me/bootstrap to create one")
			return "", nil, false
		}
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", nil, false
	}
	return t.ID, []string{"read", "write", "admin"}, true
}
