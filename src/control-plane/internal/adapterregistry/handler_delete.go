package adapterregistry

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	if !validServiceToken(r, rt.serviceToken) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	if rt.handleLookupError(w, rt.svc.Remove(r.Context(), r.PathValue("id"))) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

// removeScoped is the CALLER-SCOPED delete for the self-serve builder. It
// requires the service token (the internal trust boundary) AND resolves the
// caller tenant from the asserted identity header, then deletes ONLY a mount
// owned by that caller (the service binds `AND tenant_id = $caller`). A mount
// UUID is therefore not a bearer capability across tenants.
func (rt *routes) removeScoped(w http.ResponseWriter, r *http.Request) {
	if !validServiceToken(r, rt.serviceToken) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	userID, ok := rt.requireUser(w, r)
	if !ok {
		return
	}
	if rt.handleLookupError(w, rt.svc.RemoveScoped(r.Context(), userID, r.PathValue("id"))) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

// handleLookupError writes the response for not-found / internal errors and
// reports whether the caller should stop. Returns false on success (err == nil).
func (rt *routes) handleLookupError(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", msgNotFound)
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}

// writeRegisterError maps a Register error to its HTTP response. Conflict → 409;
// the S2 plaintext-DSN denial and the Phase 4 engine/quota denials → 403; any
// other error → 500. Byte-identical to the inline switch it replaced.
func writeRegisterError(w http.ResponseWriter, req RegisterDatabaseRequest, err error) {
	switch {
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", "database \""+req.Name+"\" already registered")
	case errors.Is(err, ErrPlaintextDsnForbidden):
		httpx.WriteError(w, http.StatusForbidden, "plaintext_dsn_forbidden", err.Error())
	case errors.Is(err, ErrEngineNotInPackage):
		httpx.WriteError(w, http.StatusForbidden, "engine_not_in_package", err.Error())
	case errors.Is(err, ErrMountQuotaExceeded):
		httpx.WriteError(w, http.StatusForbidden, "mount_quota_exceeded", err.Error())
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}

// validServiceToken reports whether the request carries a valid service token.
// It delegates to serviceauth.VerifyServiceRequest, which does a constant-time
// compare (timing-leak fix) — see serviceauth.SecureCompare.
func validServiceToken(r *http.Request, expected string) bool {
	return serviceauth.VerifyServiceRequest(r, expected)
}
