/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler_org.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:50:59 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package orgs

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handler_org.go — the org CRUD HTTP handlers.

func (rt *routes) createOrg(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.authJWT(w, r)
	if !ok {
		return
	}
	var req CreateOrgRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	o, err := rt.svc.CreateOrg(r.Context(), req, userID)
	switch {
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", "org slug already exists")
	case err != nil:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		httpx.WriteJSON(w, http.StatusCreated, o)
	}
}

func (rt *routes) listOrgs(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.authJWT(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.ListOrgsForUser(r.Context(), userID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
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
	httpx.WriteJSON(w, http.StatusOK, o)
}

func (rt *routes) updateOrg(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgUpdate); !ok {
		return
	}
	var req UpdateOrgRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	o, err := rt.svc.UpdateOrg(r.Context(), orgID, req)
	if rt.handleLookup(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, o)
}

func (rt *routes) deleteOrg(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgDelete); !ok {
		return
	}
	if rt.handleLookup(w, rt.svc.SoftDeleteOrg(r.Context(), orgID)) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}
