/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   builder_mounts_list.go                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:58:23 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:58:24 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"context"
	"net/http"

	ent "github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// mountBudget is the registered-vs-allowed mount count for the effective package.
type mountBudget struct {
	Used      int `json:"used"`
	Allowed   int `json:"allowed"`
	Remaining int `json:"remaining"`
}

// listMounts returns the caller's OWN mounts (cross-tenant isolation by
// construction — the adapter-registry GET is RLS-scoped to the asserted tenant).
// [scope: read]
func (b *builderAPI) listMounts(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := b.selfAuthScope(w, r, "read")
	if !ok {
		return
	}
	if !b.requireAdapter(w, "mount listing") {
		return
	}
	out, err := b.adapter.listMounts(r.Context(), tenantID)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "adapter_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// mountBudget computes the registered-vs-allowed mount count. Best-effort — an
// adapter outage (or no adapter) leaves used=-1 (unknown).
func (b *builderAPI) mountBudget(r *http.Request, tenantID string, allowed int) mountBudget {
	budget := mountBudget{Allowed: allowed, Used: -1}
	if b.adapter == nil {
		return budget
	}
	if mounts, lErr := b.adapter.listMounts(r.Context(), tenantID); lErr == nil {
		budget.Used = len(mounts)
		budget.Remaining = allowed - len(mounts)
		if budget.Remaining < 0 {
			budget.Remaining = 0
		}
	}
	return budget
}

// loadOrEmpty returns the stored entitlement record, or a zero record (empty
// entitlement, active) when none exists yet.
func (b *builderAPI) loadOrEmpty(ctx context.Context, slug string) ent.Record {
	rec, err := b.store.Load(ctx, slug)
	if err != nil {
		return ent.Record{TenantID: slug, Status: "active"}
	}
	return rec
}
