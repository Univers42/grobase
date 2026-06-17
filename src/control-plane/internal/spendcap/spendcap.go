// Package spendcap (Track-B B7.8) is the control-plane SPEND-CAP guard. It guards
// a public free tier against COST runaway: a tenant whose projected spend crosses
// its budget is HALTED from billable service, and at 80% of budget an ALERT fires
// once per period.
//
// It CONSUMES the B1 metering store (public.tenant_usage) and the B7.8 budgets
// table (public.tenant_budgets, migration 045) — it does NOT re-meter. On a
// periodic tick it computes each tenant's current-period SPEND in cents
// (Σ usage.qty × the per-metric cents rate), compares it to that tenant's budget,
// and publishes the SET of over-budget tenant ids to Redis (key `spend:over`).
// The Rust data plane reads that set cheaply (one SMEMBERS per refresh, an
// in-memory snapshot on the hot path) and rejects an over-budget tenant's billable
// request with a 402-class signal — so the hot path NEVER does a synchronous
// DB/Redis read per request. This is EXACTLY the cheap-snapshot pattern the B2
// QuotaGuard already uses (see internal/metering/quotaguard.go), applied to $-spend
// instead of request-count.
//
// FLAG-GATED OFF = PARITY: the guard runs only when SPEND_CAPS_ENABLED is truthy
// (default OFF); the master METERING_ENABLED is honored too (either OFF ⇒ disabled).
// With the flag off Init connects nothing, Run returns immediately, the `spend:over`
// set is never written, no alert ever fires, and (because the data plane's own
// DATA_PLANE_SPEND_CAPS also defaults OFF) the request path is byte-identical to
// today. A tenant with no tenant_budgets row, or a budget of 0, has NO cap and is
// never halted — the safe default that keeps the free tier working until an
// operator opts a tenant in.
package spendcap

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

const (
	// spendOverSet is the Redis SET the data plane reads to decide a hard halt.
	// One member per over-budget tenant_id. A tenant absent from the set is
	// under budget (or the guard is off) → served normally.
	spendOverSet = "spend:over"
	// spendOverStaging is the scratch key the guard builds the next set in, then
	// atomically RENAMEs onto spendOverSet so a reader never sees a partial set
	// (mirrors quotaguard's quota:over staging).
	spendOverStaging = "spend:over:staging"
)

// spendDB is the minimal Postgres surface the guard needs: read per-tenant
// period usage joined to its budget (AdminQuery) and stamp the once-per-period
// alert (AdminExec). The real *shared.Postgres satisfies it (the guard runs as
// the BYPASSRLS control-plane role, like the QuotaGuard); a fake satisfies it in
// unit tests so the over/under + alert decisions are provable without a database.
type spendDB interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	AdminExec(ctx context.Context, sql string, args ...any) error
}

// alerter receives the once-per-period 80% budget ALERT. The default is a
// log-only alerter (alerting integration — PagerDuty/email/webhook — is a B7.5
// concern, deliberately out of this slice); a fake captures fires in tests.
type alerter interface {
	BudgetAlert(ctx context.Context, tenantID string, spentCents, budgetCents int64, pct int)
}

// Guard evaluates per-tenant period spend vs budget and publishes the over-budget
// set + fires alerts. Mirrors the metering.QuotaGuard (Name/Mount/Init/Run) so the
// orchestrator registers it like any other sub-service.
type Guard struct {
	log      *slog.Logger
	db       spendDB
	alerter  alerter
	rates    rateTable
	rdb      *redis.Client
	enabled  bool
	redisURL string

	interval time.Duration // how often to re-evaluate
	alertPct int           // budget % at which the soft alert fires (default 80)
}

// NewGuard builds the guard from env. SPEND_CAPS_ENABLED gates everything; the
// master METERING_ENABLED is honored too (either OFF ⇒ disabled). Default OFF ⇒
// parity. The per-metric cents rates come from env (SPEND_RATE_*), so $-pricing is
// per-deployment and never baked into the byte-identical packages.json — exactly
// the convention B3 billing uses for Stripe meter ids (billing_catalog.go).
func NewGuard(log *slog.Logger, db *shared.Postgres) *Guard {
	return &Guard{
		log:      log,
		db:       db,
		alerter:  logAlerter{log: log},
		rates:    loadRateTable(),
		enabled:  shared.EnvBool("METERING_ENABLED") && shared.EnvBool("SPEND_CAPS_ENABLED"),
		redisURL: shared.EnvStr("OUTBOX_REDIS_URL", shared.EnvStr("REDIS_URL", "redis://redis:6379")),
		interval: time.Duration(shared.EnvInt("SPEND_CAPS_INTERVAL_MS", 15_000)) * time.Millisecond,
		alertPct: shared.EnvInt("SPEND_CAPS_ALERT_PCT", 80),
	}
}

// Name identifies the sub-service to the orchestrator.
func (g *Guard) Name() string { return "spend-cap" }

// Mount adds no HTTP routes — the guard is a background evaluator.
func (g *Guard) Mount(_ *http.ServeMux) {}

// Init connects Redis ONLY when enabled. Disabled ⇒ no connection ⇒ parity. An
// enabled-but-misconfigured guard (no SPEND_RATE_* rates) is fatal: a spend cap
// that can never compute a non-zero spend silently protects nothing, which is
// worse than off (the same fail-fast posture as the BillingReporter's empty
// catalog). A failed connect when enabled is fatal too (the guard cannot publish).
func (g *Guard) Init(ctx context.Context) error {
	if !g.enabled {
		g.log.Info("spend caps disabled (SPEND_CAPS_ENABLED off) — no evaluation")
		return nil
	}
	if g.rates.empty() {
		return fmt.Errorf("spend-cap: SPEND_CAPS_ENABLED but no SPEND_RATE_* rates configured (cap would protect nothing)")
	}
	if g.alertPct <= 0 || g.alertPct >= 100 {
		g.alertPct = 80
	}
	opts, err := redis.ParseURL(g.redisURL)
	if err != nil {
		return err
	}
	opts.MaxRetries = 1
	g.rdb = redis.NewClient(opts)
	if err := g.rdb.Ping(ctx).Err(); err != nil {
		return err
	}
	g.log.Info("spend caps enabled", "interval", g.interval, "alert_pct", g.alertPct,
		"metrics", g.rates.metrics(), "set", spendOverSet)
	return nil
}

// Run is the evaluation loop: every interval, recompute the over-budget set,
// publish it, and fire any due alerts. Disabled ⇒ returns immediately ⇒ parity.
// Stops on ctx cancellation. An evaluation error is logged and retried next tick
// (never fatal at steady state — a transient DB/Redis blip must not wedge the
// guard, matching the QuotaGuard's resilience contract).
func (g *Guard) Run(ctx context.Context) {
	if !g.enabled || g.rdb == nil {
		return
	}
	defer func() { _ = g.rdb.Close() }()
	if err := g.evaluate(ctx); err != nil {
		g.log.Warn("spend-cap initial evaluation failed", "err", err)
	}
	t := time.NewTicker(g.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := g.evaluate(ctx); err != nil {
				g.log.Warn("spend-cap evaluation failed", "err", err)
			}
		}
	}
}

/* ─────── env helpers (mirroring metering.consumer) ─────── */

// envBool mirrors metering.envBool / the data-plane config.rs flag shape.
