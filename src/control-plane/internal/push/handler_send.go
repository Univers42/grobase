package push

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (rt *routes) revoke(w http.ResponseWriter, r *http.Request) {
	err := rt.svc.Revoke(r.Context(), r.PathValue("id"), r.PathValue("subId"))
	if rt.handleErr(w, err) {
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *routes) send(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	res, err := rt.svc.Send(r.Context(), tenantID, req)
	if rt.handleErr(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

// handleErr maps the push service's sentinel errors to HTTP status codes.
//
//	ErrValidation    -> 400 (malformed request)
//	ErrBlockedTarget -> 400 (SSRF guard refused the target_url)
//	ErrNotFound      -> 404 (subscription not under the caller's tenant; load-bearing)
//	anything else    -> 500
func (rt *routes) handleErr(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrBlockedTarget):
		httpx.WriteError(w, http.StatusBadRequest, "blocked_target", err.Error())
	case errors.Is(err, ErrValidation):
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "push subscription not found")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
