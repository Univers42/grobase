package orgs

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// handler_org.go — the org CRUD HTTP handlers.

func (rt *routes) createOrg(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.authJWT(w, r)
	if !ok {
		return
	}
	var req CreateOrgRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if err := req.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	o, err := rt.svc.CreateOrg(r.Context(), req, userID)
	switch {
	case errors.Is(err, ErrConflict):
		shared.WriteError(w, http.StatusConflict, "conflict", "org slug already exists")
	case err != nil:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		shared.WriteJSON(w, http.StatusCreated, o)
	}
}

func (rt *routes) listOrgs(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.authJWT(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.ListOrgsForUser(r.Context(), userID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) getOrg(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgRead); !ok {
		return
	}
	o, err := rt.svc.GetOrg(r.Context(), orgID)
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, o)
}

func (rt *routes) updateOrg(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgUpdate); !ok {
		return
	}
	var req UpdateOrgRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	o, err := rt.svc.UpdateOrg(r.Context(), orgID, req)
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, o)
}

func (rt *routes) deleteOrg(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgDelete); !ok {
		return
	}
	if rt.handleLookup(w, rt.svc.SoftDeleteOrg(r.Context(), orgID)) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}
