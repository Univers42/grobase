package tenants

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (rt *routes) create(w http.ResponseWriter, r *http.Request) {
	var req CreateTenantRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	t, err := rt.svc.Create(r.Context(), req)
	switch {
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", "tenant already exists")
	case err != nil:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		httpx.WriteJSON(w, http.StatusCreated, t)
	}
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.List(r.Context())
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) findOne(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, id) {
		return
	}
	t, err := rt.svc.FindOne(r.Context(), id)
	if rt.handleLookup(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, t)
}

func (rt *routes) update(w http.ResponseWriter, r *http.Request) {
	var req UpdateTenantRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	t, err := rt.svc.Update(r.Context(), r.PathValue("id"), req)
	if rt.handleLookup(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, t)
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	if rt.handleLookup(w, rt.svc.SoftDelete(r.Context(), r.PathValue("id"))) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}
