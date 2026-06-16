package metering

// QuotaGuard (Track-B B2) is the control-plane enforcement evaluator. It CONSUMES
// the B1 metering store (public.tenant_usage) — it does NOT re-meter — and the tier
// quotas in config/packages/packages.json (embedded via internal/packages). On a
// periodic tick it sums each tenant's current-period usage for the capped metric,
// compares it to that tenant's tier quota, and publishes the SET of over-quota
// tenant ids to Redis (key `quota:over`). The Rust data plane reads that set
// cheaply (one SMEMBERS per refresh, an in-memory snapshot on the hot path) and
// rejects an over-quota tenant's request with 402 — so the hot path NEVER does a
// synchronous DB read.
//
// FLAG-GATED OFF = PARITY: the guard only runs when QUOTA_ENFORCEMENT is truthy
// (default OFF). With the flag off Init connects nothing, Run returns immediately,
// the `quota:over` set is never written, and (because the data plane's own
// DATA_PLANE_QUOTA_ENFORCEMENT also defaults OFF) the request path is byte-
// identical to today. The master METERING_ENABLED is honored too so one switch can
// disable the whole Track-B pipeline.
//
// The set is published with a copy-then-rename so a reader never sees a half-built
// set; it is also PEXPIRE'd so a crashed guard cannot leave a stale over-quota set
// enforcing forever (the data plane then sees an empty set = no enforcement, the
// fail-OPEN posture matching the rate limiter).

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

const (
	// quotaOverSet is the Redis SET the data plane reads to decide enforcement.
	// One member per over-quota tenant_id. A tenant absent from the set is
	// under quota (or enforcement is off) → served normally.
	quotaOverSet = "quota:over"
	// quotaOverStaging is the scratch key the guard builds the next set in, then
	// atomically RENAMEs onto quotaOverSet so a reader never sees a partial set.
	quotaOverStaging = "quota:over:staging"
)

// quotaReader is the minimal Postgres read surface the guard needs — one query
// that sums current-period usage per tenant joined to the tenant's plan. The
// real *shared.Postgres satisfies it; a fake satisfies it in unit tests so the
// over/under decision is provable without a live database.
type quotaReader interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// QuotaGuard evaluates per-tenant period usage vs tier quota and publishes the
// over-quota set. Mirrors the Consumer (Name/Mount/Init/Run) so the orchestrator
// registers it like any other sub-service.
type QuotaGuard struct {
	log      *slog.Logger
	db       quotaReader
	manifest *packages.Manifest
	rdb      *redis.Client
	enabled  bool
	redisURL string

	interval time.Duration // how often to re-evaluate
	metric   string        // the capped dimension (B1 metric name)

	// resolver is the OPTIONAL dynamic-builder resolver (BUILDER_ENABLED). When
	// nil (the default) isOverQuota resolves the tenant's plan via manifest.For
	// verbatim — byte-parity. When set, the EFFECTIVE (custom-overlaid, ceiling-
	// clamped) package's QueryCountCap is what the over-quota decision uses, so a
	// tenant whose custom entitlement narrowed (or an operator deal widened) its
	// query.count cap is enforced against the SAME effective cap the data plane
	// stamps. The resolver returns the same packages.Package, so QueryCountCap is
	// read identically.
	resolver quotaResolver
	// builderEnabled controls whether usageByTenantSQL joins tenant_entitlements
	// (so a stale row before a downgrade is visible to the resolver). Only true
	// when a resolver is wired; OFF leaves the query byte-identical to pre-builder.
	builderEnabled bool
}

// quotaResolver is the minimal resolve seam the guard needs (the dynamic
// builder's *entitlements.Resolver satisfies it). Kept local so metering has no
// hard dependency on the builder package and the nil default is byte-parity.
type quotaResolver interface {
	Resolve(ctx context.Context, slug, plan string) (string, packages.Package)
}

// SetResolver wires the dynamic-builder resolver (BUILDER_ENABLED). A no-op
// contract: pass nil (the default) to keep isOverQuota resolving the plan via
// manifest.For verbatim (parity). When set, the EFFECTIVE per-tenant cap is used.
func (g *QuotaGuard) SetResolver(r quotaResolver) {
	g.resolver = r
	g.builderEnabled = r != nil
}

// NewQuotaGuard builds the guard from env. QUOTA_ENFORCEMENT gates everything; the
// master METERING_ENABLED is honored too (either OFF ⇒ disabled). Default OFF ⇒
// parity. The capped metric is `query.count` (the dimension packages.json caps).
func NewQuotaGuard(log *slog.Logger, db *shared.Postgres) *QuotaGuard {
	return &QuotaGuard{
		log:      log,
		db:       db,
		enabled:  envBool("METERING_ENABLED") && envBool("QUOTA_ENFORCEMENT"),
		redisURL: env("OUTBOX_REDIS_URL", env("REDIS_URL", "redis://redis:6379")),
		interval: time.Duration(envInt("QUOTA_ENFORCEMENT_INTERVAL_MS", 15_000)) * time.Millisecond,
		metric:   env("QUOTA_ENFORCEMENT_METRIC", "query.count"),
	}
}

// Name identifies the sub-service to the orchestrator.
func (g *QuotaGuard) Name() string { return "quota-guard" }

// Mount adds no HTTP routes — the guard is a background evaluator.
func (g *QuotaGuard) Mount(_ *http.ServeMux) {}

// Init loads the tier manifest and connects Redis, ONLY when enabled. Disabled ⇒
// no manifest load, no connection ⇒ parity. A failed connect when enabled is
// fatal (the guard cannot publish decisions).
func (g *QuotaGuard) Init(ctx context.Context) error {
	if !g.enabled {
		g.log.Info("quota enforcement disabled (QUOTA_ENFORCEMENT off) — no evaluation")
		return nil
	}
	m, err := packages.Load()
	if err != nil {
		return fmt.Errorf("quota-guard: load packages manifest: %w", err)
	}
	g.manifest = m
	opts, err := redis.ParseURL(g.redisURL)
	if err != nil {
		return err
	}
	opts.MaxRetries = 1
	g.rdb = redis.NewClient(opts)
	if err := g.rdb.Ping(ctx).Err(); err != nil {
		return err
	}
	g.log.Info("quota enforcement enabled", "metric", g.metric, "interval", g.interval, "set", quotaOverSet)
	return nil
}

// Run is the evaluation loop: every interval, recompute the over-quota set and
// publish it. Disabled ⇒ returns immediately (no loop) ⇒ parity. Stops on ctx
// cancellation. An evaluation error is logged and retried next tick (never fatal
// at steady state — a transient DB/Redis blip must not wedge the guard).
func (g *QuotaGuard) Run(ctx context.Context) {
	if !g.enabled || g.rdb == nil {
		return
	}
	defer func() { _ = g.rdb.Close() }()
	// Evaluate once immediately so enforcement is live within ms of boot, not
	// after the first full interval (the gate relies on this fast first pass).
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

// evaluate recomputes the over-quota set and publishes it atomically.
func (g *QuotaGuard) evaluate(ctx context.Context) error {
	periodStart := periodStartFor(g.defaultPeriod(), time.Now().UTC())
	// BUILDER_ENABLED: join tenant_entitlements so the resolver's per-tenant cap is
	// the one enforced. Default (nil resolver) keeps the byte-identical pre-builder
	// query + manifest.For resolution.
	usageSQL := usageByTenantSQL
	if g.builderEnabled {
		usageSQL = usageByTenantBuilderSQL
	}
	rows, err := g.db.AdminQuery(ctx, usageSQL, g.metric, periodStart)
	if err != nil {
		return fmt.Errorf("quota-guard: query usage: %w", err)
	}
	over := make([]string, 0)
	for rows.Next() {
		var tenantID, plan string
		var qty int64
		if err := rows.Scan(&tenantID, &plan, &qty); err != nil {
			rows.Close()
			return fmt.Errorf("quota-guard: scan usage row: %w", err)
		}
		if g.isOverQuota(ctx, tenantID, plan, qty) {
			over = append(over, tenantID)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("quota-guard: usage rows: %w", err)
	}
	return g.publish(ctx, over)
}

// isOverQuota resolves the tenant's tier and reports whether its summed usage
// exceeds the tier's per-period cap. A tier with no cap (max / any tier without a
// quota block) is unlimited → never over quota (the parity path). The plan is
// resolved through the manifest's alias/default chain, so a stale/empty plan
// degrades to the safe baseline tier rather than going unlimited by accident.
func (g *QuotaGuard) isOverQuota(ctx context.Context, slug, plan string, qty int64) bool {
	// Dynamic builder (BUILDER_ENABLED): the EFFECTIVE per-tenant cap (custom
	// entitlement clamped to its ceiling) is what the data plane stamps, so it must
	// be what quota is enforced against. When no resolver is wired (the default),
	// resolve the plan via manifest.For verbatim — byte-identical to pre-builder.
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

// publish replaces the over-quota set atomically: clear the staging key, add the
// new members, RENAME staging→live (so a reader never sees a partial set), then
// PEXPIRE the live set so a crashed guard cannot leave a stale set enforcing
// forever. An EMPTY over set means "no tenant is over quota" — we DELETE the live
// key so the data plane's SMEMBERS returns empty (fail-OPEN: no enforcement).
func (g *QuotaGuard) publish(ctx context.Context, over []string) error {
	pipe := g.rdb.TxPipeline()
	pipe.Del(ctx, quotaOverStaging)
	if len(over) == 0 {
		// No over-quota tenants → the live set must be empty/absent.
		pipe.Del(ctx, quotaOverSet)
		if _, err := pipe.Exec(ctx); err != nil {
			return fmt.Errorf("quota-guard: publish empty set: %w", err)
		}
		g.log.Debug("quota-guard published over-quota set", "count", 0)
		return nil
	}
	members := make([]any, len(over))
	for i, m := range over {
		members[i] = m
	}
	pipe.SAdd(ctx, quotaOverStaging, members...)
	// Stale-set TTL: 3× the interval so a couple of missed ticks don't expire a
	// still-valid set, but a crashed guard's set self-clears within ~45s default.
	pipe.PExpire(ctx, quotaOverStaging, 3*g.interval)
	pipe.Rename(ctx, quotaOverStaging, quotaOverSet)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("quota-guard: publish set: %w", err)
	}
	g.log.Debug("quota-guard published over-quota set", "count", len(over))
	return nil
}

// periodStartFor returns the inclusive start of the current period for `now`.
// "hour"/"day"/"month" supported; an unknown period falls back to "month" (the
// catalog default) so a typo can never silently widen the window to "all time".
func periodStartFor(period string, now time.Time) time.Time {
	now = now.UTC()
	switch period {
	case "hour":
		return time.Date(now.Year(), now.Month(), now.Day(), now.Hour(), 0, 0, 0, time.UTC)
	case "day":
		return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	default: // "month"
		return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	}
}
