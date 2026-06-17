package webhooks

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func (rt *routes) update(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := shared.RequireTenant(w, r)
	if !ok {
		return
	}
	var req UpdateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	sub, err := rt.svc.Update(r.Context(), tenantID, r.PathValue("id"), req)
	if handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, sub)
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := shared.RequireTenant(w, r)
	if !ok {
		return
	}
	if handleLookup(w, rt.svc.Delete(r.Context(), tenantID, r.PathValue("id"))) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (rt *routes) deliveries(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := shared.RequireTenant(w, r)
	if !ok {
		return
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	out, err := rt.svc.Deliveries(r.Context(), tenantID, r.PathValue("id"), limit)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}
