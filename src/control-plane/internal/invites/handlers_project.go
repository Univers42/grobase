/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_project.go                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:50:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:50:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package invites

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handlers_project.go — STANDALONE-project direct invites. A project that belongs to an org
// must invite via a team (409); only a standalone (org-less) project's OWNER may invite users
// directly to the project. Accept then materializes a direct user→project grant (joinProject).

// gateProject gates a standalone-project invite: the project exists, is standalone (org-bound →
// 409 "invite via a team"), and the caller is the project owner.
func (rt *routes) gateProject(w http.ResponseWriter, r *http.Request, projectID string) (string, bool) {
	userID, ok := rt.auth.AuthJWT(w, r)
	if !ok {
		return "", false
	}
	orgID, exists := rt.svc.projectOrg(r.Context(), projectID)
	if !exists {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "project not found")
		return "", false
	}
	if orgID != "" {
		httpx.WriteError(w, http.StatusConflict, "conflict", "project belongs to an org; invite via a team")
		return "", false
	}
	owner, _ := rt.svc.projectOwner(r.Context(), projectID)
	if owner == "" || owner != userID {
		httpx.WriteError(w, http.StatusForbidden, "forbidden", "not the project owner")
		return "", false
	}
	return userID, true
}

func (rt *routes) issueProjectInvite(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("projectId")
	userID, ok := rt.gateProject(w, r, projectID)
	if !ok {
		return
	}
	var req IssueInviteRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if req.Role == "" {
		req.Role = "reader"
	}
	resp, err := rt.svc.Issue(r.Context(),
		IssueParams{ScopeKind: "project", ScopeID: projectID, OrgID: "", Email: req.Email, Role: req.Role}, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, resp)
}

func (rt *routes) listProjectInvites(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("projectId")
	if _, ok := rt.gateProject(w, r, projectID); !ok {
		return
	}
	list, err := rt.svc.List(r.Context(), "project", projectID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}
