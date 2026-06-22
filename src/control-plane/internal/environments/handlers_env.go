/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_env.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package environments

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handlers_env.go — environment HTTP handlers (create / list / delete).

func (rt *routes) createEnv(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("projectId")
	userID, ok := rt.requireProjectCap(w, r, projectID, orgs.CapProjGrant)
	if !ok {
		return
	}
	var req CreateEnvironmentRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	e, err := rt.svc.CreateEnvironment(r.Context(), projectID, req.Name, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, e)
}

func (rt *routes) listEnvs(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("projectId")
	if _, ok := rt.requireProjectCap(w, r, projectID, orgs.CapProjectRead); !ok {
		return
	}
	list, err := rt.svc.ListEnvironments(r.Context(), projectID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}

func (rt *routes) setScopeKey(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("projectId")
	if _, ok := rt.requireProjectCap(w, r, projectID, orgs.CapProjGrant); !ok {
		return
	}
	var req SetScopeKeyRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if req.ScopePubkey == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "scope_pubkey is required")
		return
	}
	e, err := rt.svc.SetScopeKey(r.Context(), projectID, r.PathValue("envId"), req.ScopePubkey, req.ScopeEpoch)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, e)
}

func (rt *routes) deleteEnv(w http.ResponseWriter, r *http.Request) {
	projectID := r.PathValue("projectId")
	if _, ok := rt.requireProjectCap(w, r, projectID, orgs.CapProjGrant); !ok {
		return
	}
	if err := rt.svc.DeleteEnvironment(r.Context(), projectID, r.PathValue("envId")); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}
