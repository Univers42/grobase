/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   selfserve_read.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:48 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:49 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
)

// MeResponse is the GET /v1/tenants/me body: the caller's tenant summary plus
// the resolved tier entitlements (engines / capabilities / limits / quota).
type MeResponse struct {
	Tenant       meTenant     `json:"tenant"`
	Entitlements entitlements `json:"entitlements"`
}

type meTenant struct {
	// ID is the slug — the identifier every service method keys on, matching the
	// existing /v1/tenants/{id} JSON convention (id=slug). The internal UUID is
	// surfaced separately as uuid (also matching the existing Tenant projection).
	ID     string `json:"id"`
	UUID   string `json:"uuid"`
	Slug   string `json:"slug"`
	Name   string `json:"name"`
	Plan   string `json:"plan"`
	Status string `json:"status"`
}

// entitlements is the tier's resolved offer surface, derived from the package
// manifest (config/packages/packages.json) — the single source of truth.
type entitlements struct {
	Package      string          `json:"package"`
	Engines      []string        `json:"engines"`
	Capabilities map[string]bool `json:"capabilities"`
	Limits       packages.Limits `json:"limits"`
	Quota        *packages.Quota `json:"quota,omitempty"`
}

// me returns the caller's own tenant + entitlements.
func (ss *selfServe) me(w http.ResponseWriter, r *http.Request) {
	tenantID, _, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	t, err := ss.svc.FindOne(r.Context(), tenantID)
	if ss.handleLookup(w, err) {
		return
	}
	pkgName, pkg := ss.manifest.For(t.Plan)
	resp := MeResponse{
		Tenant: meTenant{ID: t.ID, UUID: t.UUID, Slug: t.ID, Name: t.Name, Plan: t.Plan, Status: t.Status},
		Entitlements: entitlements{
			Package:      pkgName,
			Engines:      pkg.Engines,
			Capabilities: pkg.Capabilities,
			Limits:       pkg.Limits,
			Quota:        pkg.Limits.Quota,
		},
	}
	httpx.WriteJSON(w, http.StatusOK, resp)
}

// meUsage sums the caller's own tenant_usage over an optional [from,to) window.
// It runs the SAME aggregation SQL as the B1c read-back endpoint
// (GET /v1/tenants/{id}/usage) so the numbers are byte-identical — the metering
// Reader has no exported constructor (unexported db field), so the query is
// replicated here over Service's admin pool rather than reaching into the other
// package. Isolation is enforced TWICE: the tenant id comes from the credential
// (never the request), and the SQL always binds tenant_id (defense-in-depth atop
// the RLS policy on public.tenant_usage).
func (ss *selfServe) meUsage(w http.ResponseWriter, r *http.Request) {
	tenantID, _, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	metric := strings.TrimSpace(q.Get("metric"))
	from, fok := parseTimeParam(w, q.Get("from"), "from")
	if !fok {
		return
	}
	to, tok := parseTimeParam(w, q.Get("to"), "to")
	if !tok {
		return
	}
	out, err := ss.svc.aggregateUsage(r.Context(), tenantID, metric, from, to)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// listKeys returns the caller's own keys, redacted (no secret). [scope: read]
func (ss *selfServe) listKeys(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !ss.requireScope(w, scopes, "read") {
		return
	}
	out, err := ss.svc.ListKeys(r.Context(), tenantID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}
