package scim

import (
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// Mount registers the SCIM 2.0 routes onto the shared mux (Track-D D2b). The
// caller mounts this ONLY when SCIM_ENABLED is truthy (the parity gate), exactly
// like passkeys.Mount / orgs.Mount / compliance.Mount. When OFF, none of these
// routes exist and a request 404s — byte-identical to today (gotrue has no SCIM).
//
// AUTHZ — two distinct walls:
//   - /scim/v2/* (the IdP surface): BEARER token. Authorization: Bearer <token>
//     -> store.VerifyToken -> bind tenant_id (+org_id). A missing/invalid/revoked
//     token => 401. The bearer->tenant binding IS the per-tenant wall: a T1 token
//     can never read/modify a resource provisioned under T2.
//   - POST /v1/tenants/{id}/scim/tokens (the admin surface): control-plane
//     SERVICE TOKEN. Issues a bearer for a tenant; returns the cleartext ONCE.
//
// The static literal /scim/v2/Users out-ranks /scim/v2/Users/{id} (net/http
// most-specific-pattern precedence), so the list/filter and the by-id routes
// never collide. The admin (service-token) routes issue / revoke a SCIM bearer
// for a tenant; the SCIM IdP surface (bearer token) is the Users CRUD, where the
// list route supports ?filter=userName eq "x".
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}

	mux.HandleFunc("POST /v1/tenants/{id}/scim/tokens", rt.issueToken)
	mux.HandleFunc("DELETE /v1/tenants/{id}/scim/tokens/{tokenId}", rt.revokeToken)

	mux.HandleFunc("POST /scim/v2/Users", rt.createUser)
	mux.HandleFunc("GET /scim/v2/Users", rt.listUsers)
	mux.HandleFunc("GET /scim/v2/Users/{id}", rt.getUser)
	mux.HandleFunc("PUT /scim/v2/Users/{id}", rt.replaceUser)
	mux.HandleFunc("PATCH /scim/v2/Users/{id}", rt.patchUser)
	mux.HandleFunc("DELETE /scim/v2/Users/{id}", rt.deleteUser)
}

type routes struct {
	svc          *Service
	serviceToken string
}

// admin gates the issue/revoke routes on the control-plane service token.
func (rt *routes) admin(w http.ResponseWriter, r *http.Request) bool {
	if serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
	return false
}

// ── SCIM IdP surface (bearer) ────────────────────────────────────────────────

// bearer resolves the SCIM bearer token to its tenant/org binding. On any
// failure (missing/invalid/revoked) it writes a SCIM 401 and returns ok=false —
// the load-bearing reject. This IS the per-tenant wall.
func (rt *routes) bearer(w http.ResponseWriter, r *http.Request) (TokenBinding, bool) {
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	const prefix = "Bearer "
	if len(auth) <= len(prefix) || !strings.EqualFold(auth[:len(prefix)], prefix) {
		rt.scimErr(w, http.StatusUnauthorized, "Authorization: Bearer <scim-token> required")
		return TokenBinding{}, false
	}
	tok := strings.TrimSpace(auth[len(prefix):])
	b, err := rt.svc.Authorize(r.Context(), tok)
	if err != nil {
		rt.scimErr(w, http.StatusUnauthorized, "invalid or revoked SCIM token")
		return TokenBinding{}, false
	}
	return b, true
}
