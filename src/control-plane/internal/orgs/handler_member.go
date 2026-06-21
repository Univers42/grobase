/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler_member.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:50:56 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:50:58 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package orgs

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handler_member.go — the org membership HTTP handlers (list / set-role / remove).

func (rt *routes) listMembers(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgRead); !ok {
		return
	}
	out, err := rt.svc.ListMembers(r.Context(), orgID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) setMemberRole(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	targetUser := r.PathValue("userId")
	_, actorRole, ok := rt.requireCapability(w, r, orgID, CapMemberRoleSet)
	if !ok {
		return
	}
	req, ok := rt.authorizeRoleChange(w, r, roleChange{orgID: orgID, targetUser: targetUser, actorRole: actorRole})
	if !ok {
		return
	}
	err := rt.svc.SetMemberRole(r.Context(), orgID, targetUser, req.Role)
	if errors.Is(err, ErrLastOwner) {
		httpx.WriteError(w, http.StatusConflict, "conflict", "cannot demote the last owner")
		return
	}
	if rt.handleLookup(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"user_id": targetUser, "role": req.Role})
}

// roleChange bundles the role-change target/actor for authorizeRoleChange:
// orgID + targetUser identify the member; actorRole is the caller's role.
type roleChange struct {
	orgID      string
	targetUser string
	actorRole  Role
}

// authorizeRoleChange decodes the body, validates the requested role, and enforces
// the admin-vs-owner asymmetry (an admin may not mint/touch an owner). ok=false
// means a response was already written.
func (rt *routes) authorizeRoleChange(w http.ResponseWriter, r *http.Request, rc roleChange) (SetRoleRequest, bool) {
	var req SetRoleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return req, false
	}
	if !validRole(req.Role) {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error",
			"role must be one of owner|admin|developer|billing|viewer")
		return req, false
	}
	currentRole, member := rt.svc.MemberRole(r.Context(), rc.orgID, rc.targetUser)
	if !member {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "member not found")
		return req, false
	}
	if !canSetRole(rc.actorRole, Role(req.Role), currentRole) {
		httpx.WriteError(w, http.StatusForbidden, "forbidden",
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
		httpx.WriteError(w, http.StatusConflict, "conflict", "cannot remove the last owner")
		return
	}
	if rt.handleLookup(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"removed": true})
}
