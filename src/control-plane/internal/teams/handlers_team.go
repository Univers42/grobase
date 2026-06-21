/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_team.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handlers_team.go — the team CRUD HTTP handlers (org-capability gated).

func (rt *routes) createTeam(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapTeamCreate)
	if !ok {
		return
	}
	var req CreateTeamRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	t, err := rt.svc.CreateTeam(r.Context(), orgID, req, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, t)
}

func (rt *routes) listTeams(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapOrgRead); !ok {
		return
	}
	list, err := rt.svc.ListTeams(r.Context(), orgID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}

func (rt *routes) getTeam(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapOrgRead); !ok {
		return
	}
	t, err := rt.svc.GetTeam(r.Context(), orgID, r.PathValue("teamId"))
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, t)
}

func (rt *routes) updateTeam(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapTeamUpdate)
	if !ok {
		return
	}
	var req UpdateTeamRequest
	if !decodeBody(w, r, &req) {
		return
	}
	t, err := rt.svc.UpdateTeam(r.Context(), orgID, r.PathValue("teamId"), req, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, t)
}

func (rt *routes) deleteTeam(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapTeamDelete)
	if !ok {
		return
	}
	if err := rt.svc.DeleteTeam(r.Context(), orgID, r.PathValue("teamId"), userID); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}
