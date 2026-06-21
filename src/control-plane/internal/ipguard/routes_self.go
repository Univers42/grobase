/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   routes_self.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:10 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package ipguard

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// ── self-serve (/v1/tenants/me/ip-allowlist) — credential-resolved tenant ──────

func (rt *routes) meList(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := rt.selfTenant(w, r)
	if !ok {
		return
	}
	rt.writeList(w, r.Context(), tenantID)
}

func (rt *routes) meAdd(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := rt.selfTenant(w, r)
	if !ok {
		return
	}
	rt.doAdd(w, r, tenantID, "api-key")
}

func (rt *routes) meRemove(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := rt.selfTenant(w, r)
	if !ok {
		return
	}
	rt.doRemove(w, r.Context(), tenantID, r.PathValue("ruleId"))
}

// selfTenant resolves the caller's OWN tenant from a tenant API key (X-API-Key
// or Authorization: Bearer mbk_...). There is no path id, so the key is the ONLY
// tenant a request can touch. A nil resolver (not wired) ⇒ 501.
func (rt *routes) selfTenant(w http.ResponseWriter, r *http.Request) (string, bool) {
	if rt.resolver == nil {
		httpx.WriteError(w, http.StatusNotImplemented, "not_configured", "self-serve allowlist not configured")
		return "", false
	}
	raw := httpx.APIKeyFromRequest(r)
	if raw == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"X-API-Key or Authorization: Bearer <api-key> required")
		return "", false
	}
	out, err := rt.resolver.VerifyKey(r.Context(), raw)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", false
	}
	if !out.Valid || out.TenantID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_key", "API key is not valid")
		return "", false
	}
	return out.TenantID, true
}
