/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package appchannels

import (
	"errors"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// routes carries the channel service, the shared self-auth seam (resolves the caller's OWN
// app-tenant — never a path-supplied actor), and the realtime-token signing material.
type routes struct {
	svc    *Service
	auth   *tenants.SelfAuthenticator
	secret []byte
	ttl    time.Duration
}

// Deps groups the app-channel route dependencies. Secret is the shared JWT_SECRET the realtime
// plane verifies with; TTL bounds a minted realtime token's lifetime.
type Deps struct {
	Svc    *Service
	Auth   *tenants.SelfAuthenticator
	Secret string
	TTL    time.Duration
}

// Mount registers the app-channel + realtime-token routes onto the shared mux. The actor is
// always the credential's own tenant, so there is no cross-tenant path parameter anywhere.
func Mount(mux *http.ServeMux, d Deps) {
	rt := &routes{svc: d.Svc, auth: d.Auth, secret: []byte(d.Secret), ttl: d.TTL}
	mux.HandleFunc("POST /v1/app-channels", rt.open)
	mux.HandleFunc("POST /v1/app-channels/{channelId}/accept", rt.accept)
	mux.HandleFunc("GET /v1/app-channels", rt.list)
	mux.HandleFunc("POST /v1/realtime/token", rt.mintToken)
}

// actorTenant resolves the caller's own tenant from its credential and enforces a scope.
// On any failure it has already written the HTTP error; ok=false means return immediately.
func (rt *routes) actorTenant(w http.ResponseWriter, r *http.Request, need string) (string, bool) {
	tenantID, scopes, ok := rt.auth.Authenticate(w, r)
	if !ok {
		return "", false
	}
	if !hasScope(scopes, need) {
		httpx.WriteError(w, http.StatusForbidden, "forbidden", "scope '"+need+"' required")
		return "", false
	}
	return tenantID, true
}

// hasScope reports whether scopes grant want; an admin scope is a superset.
func hasScope(scopes []string, want string) bool {
	for _, s := range scopes {
		if s == want || s == "admin" || s == "apikey:admin" {
			return true
		}
	}
	return false
}

// mapErr translates a service error into the correct HTTP status without leaking internals.
func (rt *routes) mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrSameTenant):
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", err.Error())
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}
