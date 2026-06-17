// Package abuseguard (Track-B B7.9) is the control-plane ABUSE / free-tier
// KYC-lite gate. It guards a public free tier against the abuse vectors that make
// "anyone can sign up" dangerous: crypto-mining / spam-relay via runaway project
// creation, unverified throwaway accounts, and chargeback-prone unpaid usage. It
// is the explicit GO-LIVE blocker for public signup (B7.7) in the plan.
//
// It provides three things, all flag-gated OFF by default (ABUSE_GUARD_ENABLED):
//
//  1. ADMISSION — POST /v1/abuse/admit : before a sensitive action (project_create)
//     the caller asks "may principal P, tenant T, take action A?". The guard checks
//     (a) the tenant is not SUSPENDED, (b) verification gating for the tenant's tier
//     (email/phone/pay-method required?), and (c) a per-principal VELOCITY limit
//     (≤ N project_create per sliding window). A velocity breach can auto-SUSPEND.
//     Returns 200 {admit:true} or 403 {admit:false, reason}.
//  2. SUSPEND — POST /v1/abuse/suspend|unsuspend (admin): an operator (or the
//     velocity limiter) flips a tenant's suspended state. Suspended tenants are
//     published to a Redis SET (`tenant:suspended`) the data plane consults with the
//     SAME cheap-snapshot pattern as quota:over / spend:over — NO per-request DB hit.
//  3. STATE — GET /v1/abuse/state/{tenantId} (admin): the tenant's safety row.
//
// FLAG-GATED OFF = PARITY: the routes are mounted ONLY when ABUSE_GUARD_ENABLED is
// truthy (default OFF). When OFF, Mount is never called, none of the routes exist,
// no `tenant:suspended` set is written, no principal_events row is ever inserted —
// byte-identical to today (the same discipline as TENANT_SELFSERVE_ENABLED /
// TENANT_BACKUP_ENABLED in cmd/tenant-control). A tenant with no tenant_safety row
// defaults to "not suspended, verification not required" so even an enabled guard
// admits the pre-existing flow until an operator opts a tenant/tier into gating.
package abuseguard

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

const (
	// suspendedSet is the Redis SET of suspended tenant ids the data plane reads
	// cheaply (one SMEMBERS per refresh → in-memory snapshot), mirroring the
	// quota:over / spend:over convention.
	suspendedSet = "tenant:suspended"

	// ActionProjectCreate is the velocity-limited sensitive action. Kept as a
	// constant so the limiter and the migration's `action` column agree.
	ActionProjectCreate = "project_create"
)

// gdb is the minimal Postgres surface the guard needs. *shared.Postgres satisfies
// it (the guard runs as the BYPASSRLS control-plane role); a fake satisfies it in
// unit tests so the admission + velocity + suspend decisions are provable without a
// live database.
type gdb interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	AdminExec(ctx context.Context, sql string, args ...any) error
}

// requirement is the per-tier verification gate (which signals a tenant on this
// tier must have before a gated action is admitted). Loaded from env so the gating
// policy is per-deployment, never baked into the byte-identical packages.json.
type requirement struct {
	email     bool
	phone     bool
	payMethod bool
}

// Guard is the abuse/KYC-lite service. It owns HTTP routes (Mount) and, when a
// suspend changes, republishes the suspended set to Redis.
type Guard struct {
	log          *slog.Logger
	db           gdb
	rdb          *redis.Client
	serviceToken string
	enabled      bool
	redisURL     string

	// velocityMax / velocityWindow bound per-principal project_create. Default
	// 20 / hour — generous for a real user, tight enough to stop a script.
	velocityMax    int
	velocityWindow time.Duration
	// autoSuspendOnBreach: a velocity breach also SUSPENDS the tenant (not just
	// denies the one call). Default ON when the guard is on — a breach is a strong
	// abuse signal; an operator can unsuspend.
	autoSuspend bool
	// tierReqs maps a tier name → its verification requirement (ABUSE_REQUIRE_*).
	tierReqs map[string]requirement
}

// NewGuard builds the guard from env. ABUSE_GUARD_ENABLED gates everything; default
// OFF ⇒ parity. The velocity bound, window, auto-suspend, and per-tier verification
// requirements are all env-driven (per-deployment policy).
func NewGuard(log *slog.Logger, db *shared.Postgres, serviceToken string) *Guard {
	return &Guard{
		log:            log,
		db:             db,
		serviceToken:   serviceToken,
		enabled:        shared.EnvBool("ABUSE_GUARD_ENABLED"),
		redisURL:       shared.EnvStr("OUTBOX_REDIS_URL", shared.EnvStr("REDIS_URL", "redis://redis:6379")),
		velocityMax:    shared.EnvInt("ABUSE_VELOCITY_MAX", 20),
		velocityWindow: time.Duration(shared.EnvInt("ABUSE_VELOCITY_WINDOW_MS", 3_600_000)) * time.Millisecond,
		autoSuspend:    shared.EnvBoolDefault("ABUSE_AUTO_SUSPEND", true),
		tierReqs:       loadTierRequirements(),
	}
}

// Enabled reports whether the guard is on (so the caller mounts its routes only
// then — the parity gate, mirroring TENANT_SELFSERVE_ENABLED in cmd/tenant-control).
func (g *Guard) Enabled() bool { return g.enabled }

// Init connects Redis and republishes the current suspended set, ONLY when enabled.
// Disabled ⇒ no connection ⇒ parity. A failed connect when enabled is NON-fatal
// here (unlike the spend/quota guards): the admission + DB-suspend paths still work
// without Redis; only the data-plane snapshot would be stale. We log loudly and
// continue with a nil rdb (the publish helpers no-op on nil).
func (g *Guard) Init(ctx context.Context) error {
	if !g.enabled {
		g.log.Info("abuse guard disabled (ABUSE_GUARD_ENABLED off) — routes not mounted")
		return nil
	}
	opts, err := redis.ParseURL(g.redisURL)
	if err != nil {
		g.log.Warn("abuse guard: bad redis url — suspended-set publish disabled", "err", err)
		return nil
	}
	opts.MaxRetries = 1
	rdb := redis.NewClient(opts)
	if err := rdb.Ping(ctx).Err(); err != nil {
		g.log.Warn("abuse guard: redis unreachable — suspended-set publish disabled (admission still enforced)", "err", err)
		return nil
	}
	g.rdb = rdb
	if err := g.republishSuspended(ctx); err != nil {
		g.log.Warn("abuse guard: initial suspended-set publish failed", "err", err)
	}
	g.log.Info("abuse guard enabled", "velocity_max", g.velocityMax, "window", g.velocityWindow,
		"auto_suspend", g.autoSuspend, "set", suspendedSet)
	return nil
}

// loadTierRequirements reads ABUSE_REQUIRE_<TIER> env into a tier→requirement map.
// Each value is a comma list of required signals: "email,phone,pay". An absent tier
// requires nothing (the parity default — no verification gate).
func loadTierRequirements() map[string]requirement {
	out := map[string]requirement{}
	// The known tier names (packages.json keys + legacy aliases). A deployment sets
	// ABUSE_REQUIRE_NANO=email, ABUSE_REQUIRE_FREE=email,phone, etc.
	for _, tier := range []string{"nano", "basic", "essential", "pro", "max", "free", "enterprise"} {
		raw := strings.TrimSpace(shared.EnvStr("ABUSE_REQUIRE_"+strings.ToUpper(tier), ""))
		if raw == "" {
			continue
		}
		var req requirement
		for _, tok := range strings.Split(raw, ",") {
			switch strings.ToLower(strings.TrimSpace(tok)) {
			case "email":
				req.email = true
			case "phone":
				req.phone = true
			case "pay", "pay_method", "paymethod":
				req.payMethod = true
			}
		}
		out[tier] = req
	}
	return out
}
