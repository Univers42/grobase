/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   selfserve.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:54 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:55 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
)

// selfServe holds the dependencies for the tenant self-service API (B4a).
//
// A caller authenticated AS a tenant — via a tenant API key (X-API-Key /
// `Authorization: Bearer mbk_...`) OR a GoTrue user JWT — operates on its OWN
// tenant through `/v1/tenants/me*`. There is NO path id, so cross-tenant access
// is impossible by construction: every handler resolves the caller's tenant id
// from the credential and binds it into the service call. The slug a key/JWT
// resolves to is the ONLY tenant a request can ever touch.
//
// FLAG-GATED OFF = PARITY: MountSelfServe is called only when
// TENANT_SELFSERVE_ENABLED is truthy. When OFF, none of the /me routes are
// registered, so a request to them 404s exactly as it does today (byte-parity
// with the live baseline — no new path exists).
type selfServe struct {
	svc      *Service
	jwt      *JWTVerifier
	manifest *packages.Manifest
	// billing reports whether BILLING_ENABLED is set; when true a plan PATCH also
	// updates public.tenant_billing.plan. The live Stripe subscription change is a
	// SEPARATE flag-gated step (see PATCH handler TODO) — NOT in B4a.
	billing bool
	// auth is the shared self-auth seam (credential → caller's own tenant slug + scopes).
	auth *SelfAuthenticator
}

// MountSelfServe registers the six self-service routes onto the shared mux. It is
// the caller's responsibility to invoke this ONLY when TENANT_SELFSERVE_ENABLED
// is truthy (main.go gates it) — when the flag is OFF this function is never
// called and the /me routes do not exist (404 = parity).
//
// jwt may be nil (no GOTRUE_JWT_SECRET): JWT-bearer self-auth then fails 401,
// but API-key self-auth still works. The static "me" paths are registered
// alongside the existing "me/bootstrap" route; net/http's most-specific-pattern
// precedence keeps them disjoint from the parameterised {id} routes.
// SelfServeDeps groups the dependencies MountSelfServe wires into the /me route
// handlers (svc, optional JWT verifier, package manifest, billing flag).
type SelfServeDeps struct {
	Svc      *Service
	JWT      *JWTVerifier
	Manifest *packages.Manifest
	Billing  bool
}

func MountSelfServe(mux *http.ServeMux, d SelfServeDeps) {
	ss := &selfServe{
		svc: d.Svc, jwt: d.JWT, manifest: d.Manifest, billing: d.Billing,
		auth: NewSelfAuthenticator(d.Svc, d.JWT),
	}

	mux.HandleFunc("GET /v1/tenants/me", ss.me)
	mux.HandleFunc("GET /v1/tenants/me/usage", ss.meUsage)
	mux.HandleFunc("GET /v1/tenants/me/keys", ss.listKeys)
	mux.HandleFunc("POST /v1/tenants/me/keys", ss.issueKey)
	mux.HandleFunc("DELETE /v1/tenants/me/keys/{keyId}", ss.revokeKey)
	mux.HandleFunc("PATCH /v1/tenants/me", ss.patch)
}

// selfAuth resolves the caller's OWN tenant from its credential by delegating to the shared
// SelfAuthenticator (API key first, else Authorization bearer JWT). On any failure it writes
// the HTTP error and returns ok=false; the returned tenantID is the canonical SLUG.
func (ss *selfServe) selfAuth(w http.ResponseWriter, r *http.Request) (tenantID string, scopes []string, ok bool) {
	return ss.auth.Authenticate(w, r)
}
