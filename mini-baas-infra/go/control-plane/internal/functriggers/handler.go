package functriggers

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers function-trigger routes onto the shared mux.
//
// Identity: post-M11 the trust boundary forwards signed envelope headers
// (X-Baas-Tenant-Id / X-Baas-User-Id). Triggers are tenant-scoped.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/function-triggers", rt.create)
	mux.HandleFunc("GET /v1/function-triggers", rt.list)
	mux.HandleFunc("GET /v1/function-triggers/{id}", rt.findOne)
	mux.HandleFunc("PATCH /v1/function-triggers/{id}", rt.update)
	mux.HandleFunc("DELETE /v1/function-triggers/{id}", rt.remove)
	mux.HandleFunc("GET /v1/function-triggers/{id}/deliveries", rt.deliveries)
}

type routes struct {
	svc          *Service
	serviceToken string
}

func (rt *routes) create(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	var req CreateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	if err := req.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	tr, err := rt.svc.Create(r.Context(), tenantID, req)
	switch {
	case errors.Is(err, ErrConflict):
		shared.WriteError(w, http.StatusConflict, "conflict", err.Error())
	case err != nil:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		shared.WriteJSON(w, http.StatusCreated, tr)
	}
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.List(r.Context(), tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) findOne(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	tr, err := rt.svc.FindOne(r.Context(), tenantID, r.PathValue("id"))
	if handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, tr)
}

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
