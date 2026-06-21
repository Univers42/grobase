/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_accept.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package invites

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handlers_accept.go — invite acceptance (registered caller) + invite metadata.

// accept consumes an invite token for the already-registered caller (its JWT subject), joining
// them to the invited scope. The not-yet-registered path is accept-signup (a later phase).
func (rt *routes) accept(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.auth.AuthJWT(w, r)
	if !ok {
		return
	}
	var req struct {
		Token string `json:"token"`
	}
	if !decodeBody(w, r, &req) {
		return
	}
	if req.Token == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "token is required")
		return
	}
	inv, err := rt.svc.Accept(r.Context(), req.Token, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, inv)
}

// getInvite returns an invite's redacted metadata (scope, email, status) for the accept UI.
func (rt *routes) getInvite(w http.ResponseWriter, r *http.Request) {
	if _, ok := rt.auth.AuthJWT(w, r); !ok {
		return
	}
	inv, err := rt.svc.GetInvite(r.Context(), r.PathValue("inviteId"))
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, inv)
}
