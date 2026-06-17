package abuseguard

import (
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// SuspendRequest is the POST /v1/abuse/(un)suspend body.
type SuspendRequest struct {
	TenantID string `json:"tenant_id"`
	Reason   string `json:"reason,omitempty"`
}

func (rt *routes) suspend(w http.ResponseWriter, r *http.Request)   { rt.setSusp(w, r, true) }
func (rt *routes) unsuspend(w http.ResponseWriter, r *http.Request) { rt.setSusp(w, r, false) }

func (rt *routes) setSusp(w http.ResponseWriter, r *http.Request, suspended bool) {
	if !rt.authorized(w, r) {
		return
	}
	var req SuspendRequest
	if err := decodeJSON(r, &req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	if strings.TrimSpace(req.TenantID) == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "tenant_id required")
		return
	}
	reason := req.Reason
	if suspended && reason == "" {
		reason = "admin"
	}
	if err := rt.g.setSuspended(r.Context(), req.TenantID, suspended, reason); err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"tenant_id": req.TenantID, "suspended": suspended})
}
