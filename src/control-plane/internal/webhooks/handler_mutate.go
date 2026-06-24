/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler_mutate.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:01:05 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:01:06 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package webhooks

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (rt *routes) update(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := httpx.RequireTenant(w, r)
	if !ok {
		return
	}
	var req UpdateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	sub, err := rt.svc.Update(r.Context(), tenantID, r.PathValue("id"), req)
	if handleLookup(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, sub)
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := httpx.RequireTenant(w, r)
	if !ok {
		return
	}
	if handleLookup(w, rt.svc.Delete(r.Context(), tenantID, r.PathValue("id"))) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (rt *routes) deliveries(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := httpx.RequireTenant(w, r)
	if !ok {
		return
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	out, err := rt.svc.Deliveries(r.Context(), tenantID, r.PathValue("id"), limit)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}
