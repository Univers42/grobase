/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_issue.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package invites

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handlers_issue.go — team + group invite issue/list HTTP handlers.

func (rt *routes) issueTeamInvite(w http.ResponseWriter, r *http.Request) {
	orgID, teamID := r.PathValue("orgId"), r.PathValue("teamId")
	userID, ok := rt.gateTeam(w, r, orgID, teamID)
	if !ok {
		return
	}
	var req IssueInviteRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if req.Role == "" {
		req.Role = "member"
	}
	resp, err := rt.svc.Issue(r.Context(),
		IssueParams{ScopeKind: "team", ScopeID: teamID, OrgID: orgID, Email: req.Email, Role: req.Role}, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, resp)
}

func (rt *routes) listTeamInvites(w http.ResponseWriter, r *http.Request) {
	orgID, teamID := r.PathValue("orgId"), r.PathValue("teamId")
	if _, ok := rt.gateTeam(w, r, orgID, teamID); !ok {
		return
	}
	list, err := rt.svc.List(r.Context(), "team", teamID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}

func (rt *routes) issueGroupInvite(w http.ResponseWriter, r *http.Request) {
	groupID := r.PathValue("groupId")
	userID, orgID, ok := rt.gateGroup(w, r, groupID)
	if !ok {
		return
	}
	var req IssueInviteRequest
	if !decodeBody(w, r, &req) {
		return
	}
	resp, err := rt.svc.Issue(r.Context(),
		IssueParams{ScopeKind: "group", ScopeID: groupID, OrgID: orgID, Email: req.Email, Role: "member"}, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, resp)
}

func (rt *routes) listGroupInvites(w http.ResponseWriter, r *http.Request) {
	groupID := r.PathValue("groupId")
	if _, _, ok := rt.gateGroup(w, r, groupID); !ok {
		return
	}
	list, err := rt.svc.List(r.Context(), "group", groupID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}
