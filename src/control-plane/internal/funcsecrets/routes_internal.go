/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   routes_internal.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:57 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:58 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package funcsecrets

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// resolve is internal-only: it returns DECRYPTED secrets and must be protected
// by a token (the gateway also keeps /internal off the public router).
func (rt *routes) resolve(w http.ResponseWriter, r *http.Request) {
	if !rt.resolveAuthorized(r) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "invalid service token")
		return
	}
	tenant := r.URL.Query().Get("tenant")
	if tenant == "" {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "tenant required")
		return
	}
	fn := r.URL.Query().Get("function")
	secrets, err := rt.svc.Resolve(r.Context(), tenant, fn)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, secrets)
}

// resolveAuthorized accepts the scoped FUNCTION_SECRETS_TOKEN, or the shared token
// until functions-runtime stops holding it (ADR 0023 F1, devil 2026-10-30). The header
// name stays X-Internal-Service-Token: the cloud jail relay forwards only that one.
// SecureCompare refuses an empty want, so with both tokens unset every caller gets
// 401; the old `!= ""` guard let any caller in.
func (rt *routes) resolveAuthorized(r *http.Request) bool {
	got := r.Header.Get("X-Internal-Service-Token")
	return serviceauth.SecureCompare(got, rt.scopedToken) || serviceauth.SecureCompare(got, rt.serviceToken)
}

func requireTenant(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-Tenant-Id", "X-Baas-User-Id", "X-Tenant-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"missing tenant header (X-Baas-Tenant-Id, X-Baas-User-Id, X-Tenant-Id or X-User-Id)")
	return "", false
}
