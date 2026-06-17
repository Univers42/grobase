package orgs

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// handler_member.go — the org membership HTTP handlers (list / set-role / remove).

func (rt *routes) listMembers(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgRead); !ok {
		return
	}
	out, err := rt.svc.ListMembers(r.Context(), orgID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) setMemberRole(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	targetUser := r.PathValue("userId")
	_, actorRole, ok := rt.requireCapability(w, r, orgID, CapMemberRoleSet)
	if !ok {
		return
	}
	req, ok := rt.authorizeRoleChange(w, r, orgID, targetUser, actorRole)
	if !ok {
		return
	}
	err := rt.svc.SetMemberRole(r.Context(), orgID, targetUser, req.Role)
	if errors.Is(err, ErrLastOwner) {
		shared.WriteError(w, http.StatusConflict, "conflict", "cannot demote the last owner")
		return
	}
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]string{"user_id": targetUser, "role": req.Role})
}

// authorizeRoleChange decodes the body, validates the requested role, and enforces
// the admin-vs-owner asymmetry (an admin may not mint/touch an owner). ok=false
// means a response was already written.
func (rt *routes) authorizeRoleChange(w http.ResponseWriter, r *http.Request,
	orgID, targetUser string, actorRole Role) (SetRoleRequest, bool) {
	var req SetRoleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return req, false
	}
	if !validRole(req.Role) {
		shared.WriteError(w, http.StatusBadRequest, "validation_error",
			"role must be one of owner|admin|developer|billing|viewer")
		return req, false
	}
	currentRole, member := rt.svc.MemberRole(r.Context(), orgID, targetUser)
	if !member {
		shared.WriteError(w, http.StatusNotFound, "not_found", "member not found")
		return req, false
	}
	if !canSetRole(actorRole, Role(req.Role), currentRole) {
		shared.WriteError(w, http.StatusForbidden, "forbidden",
			"an admin may not create or modify an owner; only an owner can")
		return req, false
	}
	return req, true
}

func (rt *routes) removeMember(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	targetUser := r.PathValue("userId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapMemberRemove); !ok {
		return
	}
	err := rt.svc.RemoveMember(r.Context(), orgID, targetUser)
	if errors.Is(err, ErrLastOwner) {
		shared.WriteError(w, http.StatusConflict, "conflict", "cannot remove the last owner")
		return
	}
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"removed": true})
}
