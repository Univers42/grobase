/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package groups

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handler.go — the /v1/projects/{projectId}/groups + /v1/groups/{groupId}/members routes.
// Mount is called ONLY when GROUPS_ENABLED is truthy (cmd/.../mount_groups.go), so OFF ⇒ none
// of these routes exist (404 = byte-parity). The project's org is resolved server-side and
// gated via orgs.Authorizer (CapProjGrant). Standalone projects are handled in a later phase.

type routes struct {
	svc  *Service
	auth *orgs.Authorizer
}

// Deps groups the group route dependencies.
type Deps struct {
	Svc  *Service
	Auth *orgs.Authorizer
}

// Mount registers the group routes onto the shared mux. The static /members segment and the
// {userId} wildcard follow net/http most-specific-pattern precedence.
func Mount(mux *http.ServeMux, d Deps) {
	rt := &routes{svc: d.Svc, auth: d.Auth}
	mux.HandleFunc("POST /v1/projects/{projectId}/groups", rt.createGroup)
	mux.HandleFunc("GET /v1/projects/{projectId}/groups", rt.listGroups)
	mux.HandleFunc("POST /v1/groups/{groupId}/members", rt.addMember)
	mux.HandleFunc("DELETE /v1/groups/{groupId}/members/{userId}", rt.removeMember)
	mux.HandleFunc("GET /v1/groups/{groupId}/members", rt.listMembers)
}

// requireProjectManage resolves the project's org and gates on CapProjGrant; returns the
// caller, org, and project name (for deriving the group name). Standalone/missing → 404.
func (rt *routes) requireProjectManage(w http.ResponseWriter, r *http.Request, projectID string) (userID, orgID, name string, ok bool) {
	orgID, name, exists := rt.svc.projectMeta(r.Context(), projectID)
	if !exists || orgID == "" {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "project not found")
		return "", "", "", false
	}
	userID, _, ok = rt.auth.RequireCapability(w, r, orgID, orgs.CapProjGrant)
	if !ok {
		return "", "", "", false
	}
	return userID, orgID, name, true
}

// requireGroupManage resolves the group's org and gates on CapProjGrant. Standalone/missing → 404.
func (rt *routes) requireGroupManage(w http.ResponseWriter, r *http.Request, groupID string) (string, bool) {
	_, orgID, exists := rt.svc.groupMeta(r.Context(), groupID)
	if !exists || orgID == "" {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "group not found")
		return "", false
	}
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapProjGrant)
	if !ok {
		return "", false
	}
	return userID, true
}

// mapErr maps a groups sentinel error to the right HTTP status; decodeBody decodes JSON (400).
func mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "not found")
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", err.Error())
	case errors.Is(err, ErrBadReq):
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
