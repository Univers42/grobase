/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package appchannels

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// open handles POST /v1/app-channels: the caller (write scope) opens a pending channel to
// target_tenant. Idempotent — re-opening the same pair returns the existing channel.
func (rt *routes) open(w http.ResponseWriter, r *http.Request) {
	actor, ok := rt.actorTenant(w, r, "write")
	if !ok {
		return
	}
	var req OpenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return
	}
	if strings.TrimSpace(req.TargetTenant) == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "target_tenant is required")
		return
	}
	ch, err := rt.svc.Open(r.Context(), actor, req.TargetTenant)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, ch)
}

// accept handles POST /v1/app-channels/{channelId}/accept: the target side (write scope)
// consents, flipping the channel to accepted.
func (rt *routes) accept(w http.ResponseWriter, r *http.Request) {
	actor, ok := rt.actorTenant(w, r, "write")
	if !ok {
		return
	}
	ch, err := rt.svc.Accept(r.Context(), r.PathValue("channelId"), actor)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, ch)
}

// list handles GET /v1/app-channels: every channel the caller (read scope) is an end of.
func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	actor, ok := rt.actorTenant(w, r, "read")
	if !ok {
		return
	}
	chs, err := rt.svc.ListForTenant(r.Context(), actor)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, chs)
}
