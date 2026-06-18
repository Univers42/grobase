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

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

// quotaReader is the minimal Postgres read surface the guard needs — one query
// that sums current-period usage per tenant joined to the tenant's plan. The
// real *pg.Postgres satisfies it; a fake satisfies it in unit tests so the
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
func NewQuotaGuard(log *slog.Logger, db *pg.Postgres) *QuotaGuard {
	return &QuotaGuard{
		log:      log,
		db:       db,
		enabled:  config.EnvBool("METERING_ENABLED") && config.EnvBool("QUOTA_ENFORCEMENT"),
		redisURL: config.EnvStr("OUTBOX_REDIS_URL", config.EnvStr("REDIS_URL", "redis://redis:6379")),
		interval: time.Duration(config.EnvInt("QUOTA_ENFORCEMENT_INTERVAL_MS", 15_000)) * time.Millisecond,
		metric:   config.EnvStr("QUOTA_ENFORCEMENT_METRIC", "query.count"),
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
