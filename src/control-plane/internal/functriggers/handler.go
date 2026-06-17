package functriggers

import (
	"encoding/json"
	"errors"
	"net/http"

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
