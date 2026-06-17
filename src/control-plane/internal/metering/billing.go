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

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// billingRW is the Postgres surface the reporter needs: read un-reported usage
// windows (AdminQuery) and mark a window reported (AdminExec). *shared.Postgres
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
func NewBillingReporter(log *slog.Logger, db *shared.Postgres) *BillingReporter {
	return &BillingReporter{
		log:           log,
		db:            db,
		enabled:       envBool("METERING_ENABLED") && envBool("BILLING_ENABLED"),
		interval:      time.Duration(envInt("BILLING_REPORT_INTERVAL_MS", 3_600_000)) * time.Millisecond,
		lookback:      time.Duration(envInt("BILLING_REPORT_LOOKBACK_MS", 0)) * time.Millisecond,
		period:        env("BILLING_PERIOD", "month"),
		base:          env("STRIPE_API_BASE", "https://api.stripe.com"),
		apiKey:        env("STRIPE_API_KEY", ""),
		sendTimestamp: envBool("BILLING_SEND_WINDOW_TIMESTAMP"),
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

// unreportedSQL selects usage windows in the current period that have a Stripe
// customer (tenant_billing) and a billable metric and have NOT yet been reported
// (no billing_reported row). $1 = window-start floor (previous-period start −
// lookback, see billingFloor); $2 = the billable metrics (text[]). Read as the
// privileged control-plane role
// (BYPASSRLS) — it must see every tenant's rows to bill globally, exactly like the
// B1c read API and the QuotaGuard (RLS-scoping here would be a category error).
const unreportedSQL = `
SELECT u.idempotency_key, u.tenant_id, u.metric, u.qty,
       EXTRACT(EPOCH FROM u.window_start)::bigint AS window_unix,
       b.stripe_customer_id
  FROM public.tenant_usage u
  JOIN public.tenant_billing b ON b.tenant_id = u.tenant_id
  LEFT JOIN public.billing_reported r ON r.idempotency_key = u.idempotency_key
 WHERE u.window_start >= $1
   AND u.metric = ANY($2)
   AND b.stripe_customer_id <> ''
   AND r.idempotency_key IS NULL`

// markReportedSQL records a window as sent so it is never re-POSTed.
const markReportedSQL = `
INSERT INTO public.billing_reported (idempotency_key, tenant_id, metric, qty, reported_at)
VALUES ($1, $2, $3, $4, now())
ON CONFLICT (idempotency_key) DO NOTHING`

// report queries the un-reported windows and flushes them to Stripe.
func (r *BillingReporter) report(ctx context.Context) error {
	floor := r.billingFloor(time.Now().UTC())
	rows, err := r.db.AdminQuery(ctx, unreportedSQL, floor, r.catalog.metrics())
	if err != nil {
		return fmt.Errorf("billing-reporter: query usage: %w", err)
	}
	var todo []usageRow
	for rows.Next() {
		var u usageRow
		if err := rows.Scan(&u.idem, &u.tenant, &u.metric, &u.qty, &u.windowUnix, &u.customer); err != nil {
			rows.Close()
			return fmt.Errorf("billing-reporter: scan: %w", err)
		}
		todo = append(todo, u)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("billing-reporter: rows: %w", err)
	}
	return r.flush(ctx, todo)
}

// flush POSTs each window as a Stripe meter event and marks it reported. A window
// whose metric is not in the catalog is skipped (defense — the SQL already filters
// by ANY($metrics)). A POST failure leaves the window UN-marked (retried next
// tick; Stripe dedups on identifier so a retry after a partial success is safe).
// A mark failure does NOT abort the rest of the batch — the window is left
// un-marked (retried; Stripe dedup absorbs the re-POST) and we keep going, then
// return an aggregated error so the failure is visible without stranding the other
// windows. Split out from report() so the metric→event mapping + idempotency are
// unit-testable over fakes (no pgx.Rows).
func (r *BillingReporter) flush(ctx context.Context, rows []usageRow) error {
	reported, markFails := 0, 0
	var firstMarkErr error
	for _, u := range rows {
		eventName, ok := r.catalog.eventName(u.metric)
		if !ok {
			continue
		}
		var ts int64
		if r.sendTimestamp {
			ts = u.windowUnix
		}
		if err := r.biller.ReportMeterEvent(ctx, MeterEvent{
			EventName:  eventName,
			CustomerID: u.customer,
			Value:      u.qty,
			Identifier: u.idem,
			Timestamp:  ts,
		}); err != nil {
			r.log.Warn("billing: meter event failed (will retry)", "tenant", u.tenant, "metric", u.metric, "err", err)
			continue
		}
		if err := r.db.AdminExec(ctx, markReportedSQL, u.idem, u.tenant, u.metric, u.qty); err != nil {
			markFails++
			if firstMarkErr == nil {
				firstMarkErr = err
			}
			r.log.Warn("billing: ledger mark failed (window will re-POST next tick; Stripe dedups)", "tenant", u.tenant, "metric", u.metric, "err", err)
			continue
		}
		reported++
	}
	if reported > 0 {
		r.log.Info("billing reported usage windows to Stripe", "count", reported)
	}
	if firstMarkErr != nil {
		return fmt.Errorf("billing-reporter: %d ledger mark(s) failed: %w", markFails, firstMarkErr)
	}
	return nil
}

// billingFloor is the lower bound for the usage-window scan. It is ONLY a
// performance bound — the LEFT JOIN against billing_reported (r.idempotency_key IS
// NULL) is what prevents a double-bill, so widening the floor can never over-bill.
// It defaults to the start of the PREVIOUS period (minus the optional lookback),
// not the current one, so a window in the previous period's last interval that was
// never reported before the clock rolled over (reporter down at the boundary, or a
// late-ingested window) is still picked up and billed — closing the month-boundary
// revenue-loss edge. A multi-period outage needs a larger BILLING_REPORT_LOOKBACK_MS.
func (r *BillingReporter) billingFloor(now time.Time) time.Time {
	cur := periodStartFor(r.period, now)
	prev := periodStartFor(r.period, cur.Add(-time.Nanosecond)) // start of the previous period
	return prev.Add(-r.lookback)
}
