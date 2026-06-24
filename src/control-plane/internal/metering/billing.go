/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   billing.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:58 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:59 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package metering

// BillingReporter (Track-B B3) reports per-tenant usage to Stripe's billing
// meters. It CONSUMES B1's metering store (public.tenant_usage) — it does NOT
// re-meter — and the B3 tenant→customer map (public.tenant_billing). On each tick
// it finds usage WINDOWS in the current+previous period (see billingFloor) that
// (a) belong to a tenant with a Stripe customer and (b) have not yet been reported
// (a LEFT JOIN against the
// public.billing_reported sent-ledger), POSTs ONE Stripe meter event per window
// (value = the window qty, identifier = the window's B1 idempotency_key), then
// records the window in billing_reported so it is never re-sent. A re-tick thus
// re-sends nothing (local ledger), and even a crash between POST and ledger-write
// is safe because Stripe dedups on the identifier.
//
// FLAG-GATED OFF = PARITY: the reporter runs only when BILLING_ENABLED is truthy
// (and the master METERING_ENABLED). With the flag off Init connects nothing, Run
// returns immediately, NO Stripe call is ever made, and billing_reported stays
// empty — byte-identical to today. The reporter adds NO HTTP routes and NO hot
// path: it is a periodic background evaluator, like the QuotaGuard.

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// billingRW is the Postgres surface the reporter needs: read un-reported usage
// windows (AdminQuery) and mark a window reported (AdminExec). *pg.Postgres
// satisfies it (the reporter runs as the BYPASSRLS service role, like the B1c read
// API and the QuotaGuard); fakes satisfy the per-window flush logic in tests.
type billingRW interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	AdminExec(ctx context.Context, sql string, args ...any) error
}

// usageRow is one un-reported usage window joined to its Stripe customer.
type usageRow struct {
	idem       string
	tenant     string
	metric     string
	customer   string
	qty        int64
	windowUnix int64
}

// BillingReporter is the orchestrator sub-service. Mirrors the QuotaGuard
// (Name/Mount/Init/Run + an internal enabled gate) so main.go registers it like
// any other ported service.
type BillingReporter struct {
	log      *slog.Logger
	db       billingRW
	biller   Biller
	catalog  billingCatalog
	enabled  bool
	interval time.Duration
	lookback time.Duration
	period   string
	base     string
	apiKey   string
	// sendTimestamp controls whether each meter event carries the window-start
	// epoch. Default OFF (BILLING_SEND_WINDOW_TIMESTAMP) → Stripe stamps the event
	// at receipt time, which avoids the "timestamp older than Stripe's accepted
	// event horizon → permanent 4xx" trap for windows reported late (e.g. across a
	// period boundary). Operators who report promptly AND want exact period
	// attribution can turn it on.
	sendTimestamp bool
}

// NewBillingReporter builds the reporter from env. BILLING_ENABLED gates
// everything; the master METERING_ENABLED is honored too (either OFF ⇒ disabled).
// Default OFF ⇒ parity. The report cadence defaults to hourly; the period defaults
// to "month" (independent of the quota period).
func NewBillingReporter(log *slog.Logger, db *pg.Postgres) *BillingReporter {
	return &BillingReporter{
		log:           log,
		db:            db,
		enabled:       config.EnvBool("METERING_ENABLED") && config.EnvBool("BILLING_ENABLED"),
		interval:      time.Duration(config.EnvInt("BILLING_REPORT_INTERVAL_MS", 3_600_000)) * time.Millisecond,
		lookback:      time.Duration(config.EnvInt("BILLING_REPORT_LOOKBACK_MS", 0)) * time.Millisecond,
		period:        config.EnvStr("BILLING_PERIOD", "month"),
		base:          config.EnvStr("STRIPE_API_BASE", "https://api.stripe.com"),
		apiKey:        config.EnvStr("STRIPE_API_KEY", ""),
		sendTimestamp: config.EnvBool("BILLING_SEND_WINDOW_TIMESTAMP"),
	}
}

// Name identifies the sub-service to the orchestrator.
func (r *BillingReporter) Name() string { return "billing-reporter" }

// Mount adds no HTTP routes — the reporter is a background evaluator.
func (r *BillingReporter) Mount(_ *http.ServeMux) {}

// Init loads the billing catalog and builds the Stripe client, ONLY when enabled.
// Disabled ⇒ no catalog, no client ⇒ parity. Enabled-but-misconfigured (no
// BILLING_METER_* or no STRIPE_API_KEY) is fatal — a billing service that silently
// bills nothing or cannot authenticate is worse than off. A test may inject a fake
// Biller before Init; Init keeps a non-nil biller.
func (r *BillingReporter) Init(_ context.Context) error {
	if !r.enabled {
		r.log.Info("billing disabled (BILLING_ENABLED off) — no Stripe reporting")
		return nil
	}
	r.catalog = loadBillingCatalog()
	if r.catalog.empty() {
		return fmt.Errorf("billing-reporter: BILLING_ENABLED but no BILLING_METER_* configured (nothing to bill)")
	}
	if r.apiKey == "" {
		return fmt.Errorf("billing-reporter: BILLING_ENABLED but STRIPE_API_KEY is empty")
	}
	if r.biller == nil {
		r.biller = newStripeBiller(r.base, r.apiKey)
	}
	r.log.Info("billing enabled", "metrics", r.catalog.metrics(), "interval", r.interval, "base", r.base)
	return nil
}

// Run is the report loop: every interval, push un-reported usage windows to
// Stripe. Disabled ⇒ returns immediately (no loop) ⇒ parity. An evaluation error
// is logged and retried next tick (never fatal at steady state — a transient
// DB/Stripe blip must not wedge the reporter).
func (r *BillingReporter) Run(ctx context.Context) {
	if !r.enabled || r.biller == nil {
		return
	}
	if err := r.report(ctx); err != nil {
		r.log.Warn("billing initial report failed", "err", err)
	}
	t := time.NewTicker(r.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := r.report(ctx); err != nil {
				r.log.Warn("billing report failed", "err", err)
			}
		}
	}
}
