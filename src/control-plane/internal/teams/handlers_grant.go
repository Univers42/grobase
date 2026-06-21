/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_grant.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:10 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handlers_grant.go — project-role grant HTTP handlers + the effective-role probe.

func (rt *routes) grantRole(w http.ResponseWriter, r *http.Request) {
	orgID, projectID := r.PathValue("orgId"), r.PathValue("projectId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapProjGrant)
	if !ok {
		return
	}
	var req GrantRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if req.GranteeKind != "user" && req.GranteeKind != "team" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "grantee_kind must be user|team")
		return
	}
	g, err := rt.svc.Grant(r.Context(), orgID, projectID, req, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, g)
}

func (rt *routes) listGrants(w http.ResponseWriter, r *http.Request) {
	orgID, projectID := r.PathValue("orgId"), r.PathValue("projectId")
	if _, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapOrgRead); !ok {
		return
	}
	list, err := rt.svc.ListProjectGrants(r.Context(), orgID, projectID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}

func (rt *routes) revokeGrant(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapProjGrant)
	if !ok {
		return
	}
	if err := rt.svc.Revoke(r.Context(), orgID, r.PathValue("grantId"), userID); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}

func (rt *routes) effectiveRole(w http.ResponseWriter, r *http.Request) {
	orgID, projectID := r.PathValue("orgId"), r.PathValue("projectId")
	if _, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapOrgRead); !ok {
		return
	}
	target := r.URL.Query().Get("user")
	if target == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "?user= is required")
		return
	}
	role, has := rt.svc.EffectiveRole(r.Context(), orgID, projectID, target)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"user": target, "role": role, "has_access": has})
}
