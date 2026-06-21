/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:55 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:57 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package ipguard

import (
	"context"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// keyResolver maps a tenant API key (cleartext) → its owning tenant, for the
// self-serve CRUD path. *tenants.Service satisfies it via VerifyKey (the
// single-source verifier). Passing the interface (not the concrete type) keeps
// ipguard fakeable in tests; tenants does NOT import ipguard, so there is no
// import cycle. A nil resolver disables only the self-serve routes (the edge
// check + admin CRUD still work). This mirrors backup.keyResolver exactly.
type keyResolver interface {
	VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error)
}

// Mount registers the IP-allowlist edge-check + admin CRUD onto the shared mux
// (D2e). The caller mounts this ONLY when TENANT_IP_ALLOWLIST_ENABLED is truthy
// (the parity gate), exactly like audit.Mount / abuseguard.Mount. When OFF, none
// of these routes exist and a request 404s — byte-identical to today.
//
// Routes:
//
//	POST   /v1/ipguard/check                     edge decision (service-token only)
//	GET    /v1/tenants/{id}/ip-allowlist         list a tenant's rules (admin or self header)
//	POST   /v1/tenants/{id}/ip-allowlist         add a rule       (admin or self header)
//	DELETE /v1/tenants/{id}/ip-allowlist/{ruleId} remove a rule   (admin or self header)
//
// The {id} in every CRUD route is re-bound in the SQL WHERE, so a tenant can
// never read or mutate another tenant's allowlist (it can only ASK for its own id
// at the edge, and the query is tenant-scoped underneath), atop the RLS policy on
// tenant_ip_allowlist.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/ipguard/check", rt.check)
	mux.HandleFunc("GET /v1/tenants/{id}/ip-allowlist", rt.list)
	mux.HandleFunc("POST /v1/tenants/{id}/ip-allowlist", rt.add)
	mux.HandleFunc("DELETE /v1/tenants/{id}/ip-allowlist/{ruleId}", rt.remove)
}

// MountSelfServe registers the credential-resolved self-serve allowlist routes
// (/v1/tenants/me/ip-allowlist). The caller mounts this ONLY when the feature
// flag (and, by main.go's choice, TENANT_SELFSERVE_ENABLED) is truthy. resolver
// maps a tenant API key → its owning tenant; there is NO path id, so cross-tenant
// access is impossible by construction (the key resolves to exactly one tenant).
func MountSelfServe(mux *http.ServeMux, svc *Service, resolver keyResolver) {
	rt := &routes{svc: svc, resolver: resolver}
	mux.HandleFunc("GET /v1/tenants/me/ip-allowlist", rt.meList)
	mux.HandleFunc("POST /v1/tenants/me/ip-allowlist", rt.meAdd)
	mux.HandleFunc("DELETE /v1/tenants/me/ip-allowlist/{ruleId}", rt.meRemove)
}

type routes struct {
	svc          *Service
	serviceToken string
	resolver     keyResolver
}
