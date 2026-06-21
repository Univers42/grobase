/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package invites

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handler.go — the generalized invite routes (team/group issue+list, plus accept + metadata).
// Mount is called ONLY when INVITES_ENABLED is truthy (cmd/.../mount_invites.go), so OFF ⇒
// none of these routes exist (404 = byte-parity). Org-level gates reuse orgs.Authorizer.

type routes struct {
	svc  *Service
	auth *orgs.Authorizer
}

// Deps groups the invite route dependencies.
type Deps struct {
	Svc  *Service
	Auth *orgs.Authorizer
}

// Mount registers the invite routes onto the shared mux.
func Mount(mux *http.ServeMux, d Deps) {
	rt := &routes{svc: d.Svc, auth: d.Auth}
	mux.HandleFunc("POST /v1/orgs/{orgId}/teams/{teamId}/invites", rt.issueTeamInvite)
	mux.HandleFunc("GET /v1/orgs/{orgId}/teams/{teamId}/invites", rt.listTeamInvites)
	mux.HandleFunc("POST /v1/groups/{groupId}/invites", rt.issueGroupInvite)
	mux.HandleFunc("GET /v1/groups/{groupId}/invites", rt.listGroupInvites)
	mux.HandleFunc("POST /v1/invites/accept", rt.accept)
	mux.HandleFunc("GET /v1/invites/{inviteId}", rt.getInvite)
}

// gateTeam gates a team invite: an org admin (CapMemberInvite) whose org actually owns teamId.
func (rt *routes) gateTeam(w http.ResponseWriter, r *http.Request, orgID, teamID string) (string, bool) {
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapMemberInvite)
	if !ok {
		return "", false
	}
	if !rt.svc.teamInOrg(r.Context(), orgID, teamID) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "team not found")
		return "", false
	}
	return userID, true
}

// gateGroup gates a group invite: resolve the group's org and require CapProjGrant in it.
func (rt *routes) gateGroup(w http.ResponseWriter, r *http.Request, groupID string) (string, string, bool) {
	orgID, exists := rt.svc.groupOrg(r.Context(), groupID)
	if !exists || orgID == "" {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "group not found")
		return "", "", false
	}
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapProjGrant)
	if !ok {
		return "", "", false
	}
	return userID, orgID, true
}

// mapErr maps an invites sentinel error to the right HTTP status; decodeBody decodes JSON (400).
func mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrInvalid):
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
	case errors.Is(err, ErrExpired):
		httpx.WriteError(w, http.StatusGone, "expired", err.Error())
	case errors.Is(err, ErrConsumed), errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", err.Error())
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, ErrBadScope):
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}

// decodeBody decodes the JSON request body, writing 400 on failure.
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return false
	}
	return true
}
