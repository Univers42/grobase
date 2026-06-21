/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   httpauth.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:26 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:27 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package httpx

import (
	"net/http"
	"strings"
)

// cutBearer returns the token after a case-insensitive "Bearer " scheme prefix,
// and whether the prefix was present.
func cutBearer(auth string) (string, bool) {
	const p = "bearer "
	if len(auth) >= len(p) && strings.EqualFold(auth[:len(p)], p) {
		return strings.TrimSpace(auth[len(p):]), true
	}
	return "", false
}

// APIKeyFromRequest extracts a control-plane API key from a request: the
// X-API-Key header wins; otherwise an "Authorization: Bearer <key>" header is
// accepted only when the bearer value is an mbk_-prefixed API key (so a JWT in
// the same header is ignored). Returns "" when no key is present.
func APIKeyFromRequest(r *http.Request) string {
	if k := strings.TrimSpace(r.Header.Get("X-API-Key")); k != "" {
		return k
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if rest, ok := cutBearer(auth); ok && strings.HasPrefix(rest, "mbk_") {
		return rest
	}
	return ""
}

// RequireTenant resolves the caller's tenant id from the envelope header chain
// (X-Baas-Tenant-Id → X-Baas-User-Id → X-Tenant-Id → X-User-Id, first non-empty
// wins). On miss it writes a 401 and returns ok=false, so a handler can early
// return on `!ok`.
func RequireTenant(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-Tenant-Id", "X-Baas-User-Id", "X-Tenant-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	WriteError(w, http.StatusUnauthorized, "unauthorized",
		"missing tenant header (X-Baas-Tenant-Id, X-Baas-User-Id, X-Tenant-Id or X-User-Id)")
	return "", false
}
