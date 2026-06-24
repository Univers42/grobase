/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_group.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package groups

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handlers_group.go — group + group-member HTTP handlers.

func (rt *routes) createGroup(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("projectId")
	userID, orgID, name, ok := rt.requireProjectManage(w, r, projectID)
	if !ok {
		return
	}
	g, err := rt.svc.CreateGroup(r.Context(), projectID, orgID, name, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, g)
}

func (rt *routes) listGroups(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("projectId")
	if _, _, _, ok := rt.requireProjectManage(w, r, projectID); !ok {
		return
	}
	list, err := rt.svc.ListProjectGroups(r.Context(), projectID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}

func (rt *routes) addMember(w http.ResponseWriter, r *http.Request) {
	groupID := r.PathValue("groupId")
	userID, ok := rt.requireGroupManage(w, r, groupID)
	if !ok {
		return
	}
	var req AddGroupMemberRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if req.UserID == "" {
		mapErr(w, ErrBadReq)
		return
	}
	if err := rt.svc.AddGroupMember(r.Context(), groupID, req.UserID, userID); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]bool{"added": true})
}

func (rt *routes) removeMember(w http.ResponseWriter, r *http.Request) {
	groupID := r.PathValue("groupId")
	if _, ok := rt.requireGroupManage(w, r, groupID); !ok {
		return
	}
	if err := rt.svc.RemoveGroupMember(r.Context(), groupID, r.PathValue("userId")); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"removed": true})
}

func (rt *routes) listMembers(w http.ResponseWriter, r *http.Request) {
	groupID := r.PathValue("groupId")
	if _, ok := rt.requireGroupManage(w, r, groupID); !ok {
		return
	}
	list, err := rt.svc.ListGroupMembers(r.Context(), groupID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}
