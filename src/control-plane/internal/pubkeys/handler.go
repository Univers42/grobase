/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 07:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 07:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pubkeys

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handler.go — the pubkey registry + grant-fulfilment routes. Mount is called ONLY when
// USER_PUBKEYS_ENABLED is truthy (cmd/.../mount_pubkeys.go), so OFF ⇒ none of these routes
// exist (404 = byte-parity). Org-level gates reuse orgs.Authorizer.

type routes struct {
	svc  *Service
	auth *orgs.Authorizer
}

// Deps groups the pubkey route dependencies.
type Deps struct {
	Svc  *Service
	Auth *orgs.Authorizer
}

// Mount registers the pubkey routes onto the shared mux.
func Mount(mux *http.ServeMux, d Deps) {
	rt := &routes{svc: d.Svc, auth: d.Auth}
	mux.HandleFunc("PUT /v1/orgs/{orgId}/pubkey", rt.putPubkey)
	mux.HandleFunc("GET /v1/orgs/{orgId}/users/{userId}/pubkey", rt.getPubkey)
	mux.HandleFunc("POST /v1/orgs/{orgId}/projects/{projectId}/grants/{grantId}/wraps", rt.recordWrap)
	mux.HandleFunc("GET /v1/orgs/{orgId}/projects/{projectId}/grants/{grantId}/fulfilled", rt.fulfilled)
}

// gateMember gates a read/register on org membership (CapOrgRead — every member has it).
func (rt *routes) gateMember(w http.ResponseWriter, r *http.Request, orgID string) (string, bool) {
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapOrgRead)
	return userID, ok
}

// gateAdmin gates a wrap-record on CapProjGrant (only a key-holding admin records a wrap).
func (rt *routes) gateAdmin(w http.ResponseWriter, r *http.Request, orgID string) (string, bool) {
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapProjGrant)
	return userID, ok
}

// mapErr maps a pubkeys sentinel error to the right HTTP status; decodeBody decodes JSON (400).
func mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "not found")
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
