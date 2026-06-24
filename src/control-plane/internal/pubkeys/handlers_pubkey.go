/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers_pubkey.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 07:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 07:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pubkeys

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handlers_pubkey.go — pubkey register/read + wrap-record/fulfilment HTTP handlers.

func (rt *routes) putPubkey(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, ok := rt.gateMember(w, r, orgID)
	if !ok {
		return
	}
	var req RegisterPubkeyRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if req.X25519Pub == "" || req.V42Address == "" || req.PubkeySig == "" {
		mapErr(w, ErrBadReq)
		return
	}
	p, err := rt.svc.Register(r.Context(), orgID, userID, req)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, p)
}

func (rt *routes) getPubkey(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, ok := rt.gateMember(w, r, orgID); !ok {
		return
	}
	p, err := rt.svc.Get(r.Context(), orgID, r.PathValue("userId"))
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, p)
}

func (rt *routes) recordWrap(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, ok := rt.gateAdmin(w, r, orgID); !ok {
		return
	}
	var req struct {
		UserID string `json:"user_id"`
	}
	if !decodeBody(w, r, &req) {
		return
	}
	if req.UserID == "" {
		mapErr(w, ErrBadReq)
		return
	}
	if err := rt.svc.RecordWrap(r.Context(), orgID, r.PathValue("grantId"), req.UserID); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]bool{"wrapped": true})
}

func (rt *routes) fulfilled(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, ok := rt.gateMember(w, r, orgID); !ok {
		return
	}
	res, err := rt.svc.Fulfilled(r.Context(), r.PathValue("grantId"))
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}
