/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   authenticator.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// SelfAuthenticator resolves the caller's OWN tenant from its credential — a tenant API key
// (X-API-Key / Authorization: Bearer mbk_...) or a GoTrue user JWT. It is the shared self-auth
// seam: /v1/tenants/me* and /v1/app-channels both bind the resolved tenant, never a path id, so
// cross-tenant access is impossible by construction. The resolved tenantID is the canonical SLUG.
type SelfAuthenticator struct {
	svc *Service
	jwt *JWTVerifier
}

// NewSelfAuthenticator wires the tenant service (required) and JWT verifier (optional; nil ⇒
// JWT-bearer self-auth fails 401 but API-key self-auth still works).
func NewSelfAuthenticator(svc *Service, jwt *JWTVerifier) *SelfAuthenticator {
	return &SelfAuthenticator{svc: svc, jwt: jwt}
}

// Authenticate resolves the caller's tenant: an API key first, else an Authorization bearer JWT.
// On any failure it writes a 401/404 and returns ok=false.
func (a *SelfAuthenticator) Authenticate(w http.ResponseWriter, r *http.Request) (tenantID string, scopes []string, ok bool) {
	if raw := httpx.APIKeyFromRequest(r); raw != "" {
		return a.authByAPIKey(w, r, raw)
	}
	if auth := strings.TrimSpace(r.Header.Get("Authorization")); auth != "" {
		return a.authByJWT(w, r, auth)
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"X-API-Key, Authorization: Bearer <api-key>, or Authorization: Bearer <jwt> required")
	return "", nil, false
}

// AuthUser resolves only the caller's account user id from a GoTrue JWT — no tenant lookup, so
// an account with no tenant yet can still create its first app. JWT-only (an API key has no user).
func (a *SelfAuthenticator) AuthUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if a.jwt == nil || auth == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "Authorization: Bearer <jwt> required")
		return "", false
	}
	identity, err := a.jwt.Verify(auth)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
		return "", false
	}
	return identity.UserID, true
}

// authByAPIKey resolves the caller's tenant from a verified tenant API key.
func (a *SelfAuthenticator) authByAPIKey(w http.ResponseWriter, r *http.Request, raw string) (string, []string, bool) {
	out, err := a.svc.VerifyKey(r.Context(), raw)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", nil, false
	}
	if !out.Valid {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_key", "API key is not valid")
		return "", nil, false
	}
	return out.TenantID, out.Scopes, true
}

// authByJWT resolves the caller's tenant from a GoTrue user JWT (RESOLVE-ONLY: no tenant is
// created here; an owner-less user gets 404 pointing at /me/bootstrap). A JWT-authenticated
// user is the tenant OWNER, so it gets full self-management scopes once resolved.
func (a *SelfAuthenticator) authByJWT(w http.ResponseWriter, r *http.Request, auth string) (string, []string, bool) {
	if a.jwt == nil {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"JWT self-auth not configured (no GOTRUE_JWT_SECRET); use an API key")
		return "", nil, false
	}
	identity, err := a.jwt.Verify(auth)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
		return "", nil, false
	}
	t, err := a.svc.findForUser(r.Context(), identity.UserID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			httpx.WriteError(w, http.StatusNotFound, "no_tenant",
				"no tenant for this user yet — POST /v1/tenants/me/bootstrap to create one")
			return "", nil, false
		}
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", nil, false
	}
	return t.ID, []string{"read", "write", "admin"}, true
}
