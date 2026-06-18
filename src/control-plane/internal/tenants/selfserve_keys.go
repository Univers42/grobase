package tenants

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// issueKey mints a new key for the caller's own tenant; the full secret is
// returned ONCE. [scope: write or admin]
func (ss *selfServe) issueKey(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !ss.requireScope(w, scopes, "write") {
		return
	}
	var req IssueKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if !ss.containScopes(w, &req, scopes) {
		return
	}
	out, err := ss.svc.IssueKey(r.Context(), tenantID, req)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, out)
}

// containScopes enforces scope containment: a caller may never mint a key
// broader than its own credential. Without this a `write`-only key could issue
// an `admin` key (the write gate is satisfied) and reach admin-only operations
// like PATCH /me {plan} — a within-tenant privilege escalation. It resolves the
// effective scopes (mirroring the service's empty->{read,write} default), writes
// the effective set back into req, and returns false (after a 403) on overreach.
func (ss *selfServe) containScopes(w http.ResponseWriter, req *IssueKeyRequest, held []string) bool {
	eff, ok := scopesWithinCaller(req.Scopes, held)
	if !ok {
		httpx.WriteError(w, http.StatusForbidden, "forbidden",
			"cannot issue a key with scopes broader than your own credential")
		return false
	}
	req.Scopes = eff
	return true
}

// revokeKey revokes one of the caller's own keys by id. The RevokeKey SQL binds
// BOTH the key id AND the tenant slug, so a caller can never revoke another
// tenant's key even if it guessed the uuid. [scope: write or admin]
func (ss *selfServe) revokeKey(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !ss.requireScope(w, scopes, "write") {
		return
	}
	if ss.handleLookup(w, ss.svc.RevokeKey(r.Context(), tenantID, r.PathValue("keyId"))) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}
