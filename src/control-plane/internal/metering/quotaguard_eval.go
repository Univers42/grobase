/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   quotaguard_eval.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:47:11 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:47:13 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package metering

import (
	"context"
	"fmt"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/jackc/pgx/v5"
)

// usageByTenantSQL sums the capped metric over the current period per tenant,
// joining tenant_usage to tenants for the plan. tenant_usage.tenant_id holds the
// tenant SLUG (the public identity the data plane stamps from the signed
// envelope — see migration 032), NOT the tenants.id UUID, so the join is
// slug→slug (tenants.slug). A tenant_id present in usage but absent from tenants
// resolves to NULL plan → the manifest's default_package (the safe baseline
// tier), matching packages.Manifest.For. window_start >= $2 scopes to the
// current period; $1 is the capped metric.
//
// The guard reads tenant_usage as the privileged control-plane role (BYPASSRLS),
// exactly like the B1c read-API and the ingest consumer — it must see EVERY
// tenant's rows to enforce globally, so RLS-scoping here would be a category
// error (the per-tenant isolation guarantee is for tenant-facing reads).
const usageByTenantSQL = `
SELECT u.tenant_id, COALESCE(t.plan, '') AS plan, COALESCE(SUM(u.qty), 0)::bigint AS qty
  FROM public.tenant_usage u
  LEFT JOIN public.tenants t ON t.slug = u.tenant_id
 WHERE u.metric = $1
   AND u.window_start >= $2
 GROUP BY u.tenant_id, t.plan`

// usageByTenantBuilderSQL is the BUILDER_ENABLED variant. It is byte-equivalent
// to usageByTenantSQL for the plan/qty columns, but additionally LEFT JOINs
// public.tenant_entitlements so the resolve step has the row available without a
// per-tenant round-trip (the resolver re-reads it; the join also keeps the SQL
// honest that the table participates). A tenant with no entitlement row resolves
// the named tier (parity). Only used when a builder resolver is wired; the
// default path uses usageByTenantSQL, byte-identical to pre-builder.
const usageByTenantBuilderSQL = `
SELECT u.tenant_id, COALESCE(t.plan, '') AS plan, COALESCE(SUM(u.qty), 0)::bigint AS qty
  FROM public.tenant_usage u
  LEFT JOIN public.tenants t              ON t.slug      = u.tenant_id
  LEFT JOIN public.tenant_entitlements te ON te.tenant_id = u.tenant_id
 WHERE u.metric = $1
   AND u.window_start >= $2
 GROUP BY u.tenant_id, t.plan`

// Run is the evaluation loop: every interval, recompute the over-quota set and
// publish it. Disabled ⇒ returns immediately (no loop) ⇒ parity. Stops on ctx
// cancellation. An evaluation error is logged and retried next tick (never fatal
// at steady state — a transient DB/Redis blip must not wedge the guard). The
// first evaluation runs immediately, before the ticker starts, so enforcement is
// live within ms of boot rather than after a full interval (the gate relies on
// this fast first pass).
func (g *QuotaGuard) Run(ctx context.Context) {
	if !g.enabled || g.rdb == nil {
		return
	}
	defer func() { _ = g.rdb.Close() }()
	if err := g.evaluate(ctx); err != nil {
		g.log.Warn("quota-guard initial evaluation failed", "err", err)
	}
	t := time.NewTicker(g.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := g.evaluate(ctx); err != nil {
				g.log.Warn("quota-guard evaluation failed", "err", err)
			}
		}
	}
}

// evaluate recomputes the over-quota set and publishes it atomically. Under
// BUILDER_ENABLED it queries the variant that joins tenant_entitlements so the
// resolver's per-tenant cap is the one enforced; the default (nil resolver) keeps
// the byte-identical pre-builder query + manifest.For resolution.
func (g *QuotaGuard) evaluate(ctx context.Context) error {
	periodStart := periodStartFor(g.defaultPeriod(), time.Now().UTC())
	usageSQL := usageByTenantSQL
	if g.builderEnabled {
		usageSQL = usageByTenantBuilderSQL
	}
	rows, err := g.db.AdminQuery(ctx, usageSQL, g.metric, periodStart)
	if err != nil {
		return fmt.Errorf("quota-guard: query usage: %w", err)
	}
	over, err := g.scanOverQuota(ctx, rows)
	if err != nil {
		return err
	}
	return g.publish(ctx, over)
}

// scanOverQuota drains the usage cursor into the set of over-quota tenant ids.
func (g *QuotaGuard) scanOverQuota(ctx context.Context, rows pgx.Rows) ([]string, error) {
	defer rows.Close()
	over := make([]string, 0)
	for rows.Next() {
		var tenantID, plan string
		var qty int64
		if err := rows.Scan(&tenantID, &plan, &qty); err != nil {
			return nil, fmt.Errorf("quota-guard: scan usage row: %w", err)
		}
		if g.isOverQuota(ctx, tenantID, plan, qty) {
			over = append(over, tenantID)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("quota-guard: usage rows: %w", err)
	}
	return over, nil
}

// isOverQuota resolves the tenant's tier and reports whether its summed usage
// exceeds the tier's per-period cap. A tier with no cap (max / any tier without a
// quota block) is unlimited → never over quota (the parity path). The plan is
// resolved through the manifest's alias/default chain, so a stale/empty plan
// degrades to the safe baseline tier rather than going unlimited by accident.
// Under the dynamic builder (BUILDER_ENABLED) the EFFECTIVE per-tenant cap (custom
// entitlement clamped to its ceiling) is what the data plane stamps, so it must be
// what quota is enforced against; when no resolver is wired (the default) the plan
// resolves via manifest.For verbatim — byte-identical to pre-builder.
func (g *QuotaGuard) isOverQuota(ctx context.Context, slug, plan string, qty int64) bool {
	var pkg packages.Package
	if g.resolver != nil {
		_, pkg = g.resolver.Resolve(ctx, slug, plan)
	} else {
		_, pkg = g.manifest.For(plan)
	}
	cap, capped := pkg.QueryCountCap()
	if !capped {
		return false
	}
	return qty >= 0 && uint64(qty) > cap
}

// defaultPeriod is the period the capped tiers use (they all share "month"
// today). Resolved from the default package so a single-period catalog has one
// source; a future per-tier period would move this into the per-tenant loop.
func (g *QuotaGuard) defaultPeriod() string {
	if g.manifest == nil {
		return "month"
	}
	_, pkg := g.manifest.For(g.manifest.DefaultPackage)
	return pkg.QuotaPeriod()
}
