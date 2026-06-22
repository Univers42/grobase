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

package environments

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handler.go — the /v1/projects/{projectId}/environments* routes. Mount is called ONLY when
// ENVIRONMENTS_ENABLED is truthy (cmd/.../mount_groups.go), so OFF ⇒ none of these routes
// exist (404 = byte-parity). The project's org is resolved server-side and gated via
// orgs.Authorizer (CapProjGrant). Standalone (org-less) projects are handled in a later phase.

type routes struct {
	svc  *Service
	auth *orgs.Authorizer
}

// Deps groups the environment route dependencies.
type Deps struct {
	Svc  *Service
	Auth *orgs.Authorizer
}

// Mount registers the environment routes onto the shared mux.
func Mount(mux *http.ServeMux, d Deps) {
	rt := &routes{svc: d.Svc, auth: d.Auth}
	mux.HandleFunc("POST /v1/projects/{projectId}/environments", rt.createEnv)
	mux.HandleFunc("GET /v1/projects/{projectId}/environments", rt.listEnvs)
	mux.HandleFunc("PUT /v1/projects/{projectId}/environments/{envId}/scopekey", rt.setScopeKey)
	mux.HandleFunc("DELETE /v1/projects/{projectId}/environments/{envId}", rt.deleteEnv)
}

// requireProjectCap resolves the project's org and gates on cap in it. A missing or
// standalone (org-less) project → 404 (standalone management lands in a later phase).
// Mutations pass CapProjGrant; listing env metadata passes the read cap CapProjectRead —
// env names + PUBLIC scope keys leak nothing (the seal gates decryption), so any granted
// member (always an org member) must resolve an env to read or write its secrets.
func (rt *routes) requireProjectCap(w http.ResponseWriter, r *http.Request, projectID, cap string) (string, bool) {
	orgID, exists := rt.svc.projectMeta(r.Context(), projectID)
	if !exists || orgID == "" {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "project not found")
		return "", false
	}
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, cap)
	if !ok {
		return "", false
	}
	return userID, true
}

// decodeBody decodes the JSON request body, writing 400 on failure.
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return false
	}
	return true
}

// mapErr maps an environments sentinel error to the right HTTP status.
func mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "not found")
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", err.Error())
	case errors.Is(err, ErrBadName):
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}
