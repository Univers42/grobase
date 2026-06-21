/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler_crud.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:01:02 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:01:04 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package webhooks

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (rt *routes) create(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := httpx.RequireTenant(w, r)
	if !ok {
		return
	}
	var req CreateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	sub, err := rt.svc.Create(r.Context(), tenantID, req)
	switch {
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", err.Error())
	case err != nil:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		httpx.WriteJSON(w, http.StatusCreated, sub)
	}
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := httpx.RequireTenant(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.List(r.Context(), tenantID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) findOne(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := httpx.RequireTenant(w, r)
	if !ok {
		return
	}
	sub, err := rt.svc.FindOne(r.Context(), tenantID, r.PathValue("id"))
	if handleLookup(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, sub)
}
