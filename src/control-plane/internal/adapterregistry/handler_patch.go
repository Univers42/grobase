/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler_patch.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 23:55:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 23:55:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (rt *routes) patch(w http.ResponseWriter, r *http.Request) {
	if !rt.validServiceToken(r) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	userID, ok := rt.requireUser(w, r)
	if !ok {
		return
	}
	var req PatchDatabaseRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPatchBodyBytes)).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	descriptor, err := rt.svc.Patch(r.Context(), userID, r.PathValue("id"), req)
	if err != nil {
		writePatchError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, descriptor)
}

func writePatchError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", msgNotFound)
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", ErrConflict.Error())
	case errors.Is(err, ErrCredentialModeMismatch):
		httpx.WriteError(w, http.StatusConflict, "credential_mode_mismatch", ErrCredentialModeMismatch.Error())
	case errors.Is(err, ErrCMEKUnavailable):
		httpx.WriteError(w, http.StatusConflict, "cmek_unavailable", ErrCMEKUnavailable.Error())
	case errors.Is(err, ErrRevisionConflict):
		httpx.WriteError(w, http.StatusConflict, "revision_conflict", ErrRevisionConflict.Error())
	case errors.Is(err, ErrPlatformMount):
		httpx.WriteError(w, http.StatusForbidden, "platform_mount", ErrPlatformMount.Error())
	case errors.Is(err, ErrPlaintextDsnForbidden):
		httpx.WriteError(w, http.StatusForbidden, "plaintext_dsn_forbidden", ErrPlaintextDsnForbidden.Error())
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "internal server error")
	}
}
