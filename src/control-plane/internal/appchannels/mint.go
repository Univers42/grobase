/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mint.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package appchannels

import (
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// mintToken handles POST /v1/realtime/token: it issues the caller (read scope) a short-lived
// realtime JWT scoped to EXACTLY its accepted channels — namespaces = xapp:<id> per accepted
// channel and NOTHING else (no wildcard). Without "*" the token is denied the `**`/`*` glob
// patterns, so it can publish/subscribe only on its own channels and reaches no other topic.
func (rt *routes) mintToken(w http.ResponseWriter, r *http.Request) {
	actor, ok := rt.actorTenant(w, r, "read")
	if !ok {
		return
	}
	chIDs, err := rt.svc.AcceptedChannelIDs(r.Context(), actor)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	token, exp, ns, err := rt.mintRealtimeToken(actor, chIDs)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, MintResponse{Token: token, ExpiresAt: exp, Namespaces: ns})
}

// mintRealtimeToken signs an HS256 realtime JWT with the shared JWT_SECRET (same secret the
// realtime plane verifies with). Returns the token, its expiry (unix), and the granted namespaces.
func (rt *routes) mintRealtimeToken(sub string, chIDs []string) (string, int64, []string, error) {
	if len(rt.secret) == 0 {
		return "", 0, nil, errNoSecret
	}
	ns := realtimeNamespaces(chIDs)
	now := time.Now()
	exp := now.Add(rt.ttl)
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, realtimeClaims(sub, ns, now, exp))
	signed, err := tok.SignedString(rt.secret)
	if err != nil {
		return "", 0, nil, err
	}
	return signed, exp.Unix(), ns, nil
}

// realtimeNamespaces builds the namespace grant: exactly one xapp:<id> per accepted channel,
// no wildcard. An empty list (no accepted channels) grants nothing — the token reaches no topic.
func realtimeNamespaces(chIDs []string) []string {
	ns := make([]string, 0, len(chIDs))
	for _, id := range chIDs {
		ns = append(ns, "xapp:"+id)
	}
	return ns
}

// realtimeClaims assembles the realtime-plane claim set (sub/iat/exp + namespaces + pub/sub).
func realtimeClaims(sub string, namespaces []string, now, exp time.Time) jwt.MapClaims {
	return jwt.MapClaims{
		"sub":           sub,
		"iat":           now.Unix(),
		"exp":           exp.Unix(),
		"namespaces":    namespaces,
		"can_publish":   true,
		"can_subscribe": true,
	}
}
