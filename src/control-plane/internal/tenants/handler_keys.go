/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler_keys.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:58:49 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:58:51 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (rt *routes) issueKey(w http.ResponseWriter, r *http.Request) {
	var req IssueKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	out, err := rt.svc.IssueKey(r.Context(), r.PathValue("id"), req)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, out)
}

func (rt *routes) listKeys(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListKeys(r.Context(), r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) revokeKey(w http.ResponseWriter, r *http.Request) {
	if rt.handleLookup(w, rt.svc.RevokeKey(r.Context(), r.PathValue("id"), r.PathValue("keyId"))) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}

func (rt *routes) verifyKey(w http.ResponseWriter, r *http.Request) {
	var req VerifyKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	out, err := rt.svc.VerifyKey(r.Context(), req.Key)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	status := http.StatusOK
	if !out.Valid {
		status = http.StatusUnauthorized
	}
	httpx.WriteJSON(w, status, out)
}
