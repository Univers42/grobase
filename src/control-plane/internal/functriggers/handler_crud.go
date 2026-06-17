package functriggers

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func (rt *routes) update(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	var req UpdateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	tr, err := rt.svc.Update(r.Context(), tenantID, r.PathValue("id"), req)
	if handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, tr)
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	if handleLookup(w, rt.svc.Delete(r.Context(), tenantID, r.PathValue("id"))) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (rt *routes) deliveries(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
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

func handleLookup(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "function trigger not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}

func requireTenant(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-Tenant-Id", "X-Baas-User-Id", "X-Tenant-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"missing tenant header (X-Baas-Tenant-Id, X-Baas-User-Id, X-Tenant-Id or X-User-Id)")
	return "", false
}
