// Package entitlements is the control-plane DYNAMIC BUILDER core (BUILDER_ENABLED).
//
// It lets a tenant COMPOSE its own effective package — fewer mounts, narrowed
// capabilities, a lower rps, a subset of allowed engines, fewer addons — and lets
// an OPERATOR mint a custom entitlement + a per-tenant ceiling (a sales deal),
// all WITHOUT a rebuild. The whole feature is a control-plane RESOLVER SWAP:
// everywhere the control plane used `manifest.For(plan)` it can instead call
// Resolver.Resolve(tenant), which returns a synthesized packages.Package — the
// named tier OVERLAID by the tenant's custom entitlement and CLAMPED to a ceiling.
// Because CapabilityOverrides(), QueryCountCap(), AllowsEngine(), and PoolPolicy
// are all methods on packages.Package, the synthesized package makes the
// capability_overrides STAMP, the quota guard, the engine allowlist, max_mounts,
// and the rate limiter all work UNCHANGED — ZERO Rust changes.
//
// The state lives in public.tenant_entitlements (migration 062): one row per
// tenant (slug PK) carrying the custom entitlement JSON, an optional operator
// ceiling_plan, and a status. The CEILING is a PRIVILEGE BOUNDARY enforced at TWO
// points: ValidateWithin at COMPOSE time (a clean 403) and Clamp at RESOLVE time
// (the BACKSTOP — a stale over-ceiling row is clamped on EVERY resolve, never
// trusted). This file is the durable Store; resolver.go is the resolver.
//
// FLAG-GATED OFF = PARITY: the Resolver is nil/disabled unless BUILDER_ENABLED
// (and the table is empty/unread), so Resolve degrades to manifest.For(plan)
// verbatim — byte-identical to the pre-builder baseline.
package entitlements

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/jackc/pgx/v5"
)

// pgIface is the minimal Postgres surface the Store needs (admin/BYPASSRLS read +
// write, exactly like the other Track-B/D stores). The real *shared.Postgres
// satisfies it; a fake satisfies it in unit tests so Resolve is provable without
// a live DB.
type pgIface interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	AdminExec(ctx context.Context, sql string, args ...any) error
}

// ErrNotFound is returned by Load when no entitlement row exists for the slug.
var ErrNotFound = errors.New("no entitlement for tenant")

// CustomEntitlement is the per-tenant overlay a tenant composes (or an operator
// mints). It is a SUBSET projection of packages.Package's tunable axes — exactly
// the fields a tenant may narrow within its ceiling. Unmarshalled from the
// tenant_entitlements.entitlement JSONB column. A nil/absent field means "inherit
// the ceiling" (NOT "unlimited") — Clamp enforces that.
//
// It maps 1:1 onto a packages.Package via ToPackage() so Clamp/ValidateWithin
// operate on the same type the rest of the control plane uses.
type CustomEntitlement struct {
	Label        string             `json:"label,omitempty"`
	Engines      []string           `json:"engines,omitempty"`
	Capabilities map[string]bool    `json:"capabilities,omitempty"`
	Limits       *EntitlementLimits `json:"limits,omitempty"`
	MaxConn      *int               `json:"max_conn,omitempty"`
	MaxMounts    *int               `json:"max_mounts,omitempty"`
	Addons       []string           `json:"addons,omitempty"`
	SecurityMode string             `json:"security_mode,omitempty"`
}

// EntitlementLimits mirrors the tunable subset of packages.Limits a tenant may
// narrow. Pointers distinguish "absent → inherit" from an explicit zero.
type EntitlementLimits struct {
	RPS        *uint32 `json:"rps,omitempty"`
	Burst      *uint32 `json:"burst,omitempty"`
	MaxRows    *uint32 `json:"max_rows,omitempty"`
	QueryCount *uint64 `json:"quota.query.count,omitempty"`
}

// Record is one stored entitlement row.
type Record struct {
	TenantID    string            `json:"tenant_id"`
	Entitlement CustomEntitlement `json:"entitlement"`
	CeilingPlan string            `json:"ceiling_plan,omitempty"` // operator-set; "" = use the tenant's plan
	Status      string            `json:"status"`                 // active | draft
}

// ToPackage projects a CustomEntitlement onto a packages.Package so the pure
// Clamp/ValidateWithin operate on a single type. Absent (nil/empty) fields map to
// the package zero value, which Clamp interprets as "inherit the ceiling".
// Exported so the tenant-control builder API (a different package) can run the
// SAME Clamp/ValidateWithin the resolver runs.
func (c CustomEntitlement) ToPackage() packages.Package {
	p := packages.Package{
		Label:        c.Label,
		Engines:      c.Engines,
		Capabilities: c.Capabilities,
		Addons:       c.Addons,
		SecurityMode: c.SecurityMode,
	}
	if c.Limits != nil {
		if c.Limits.RPS != nil {
			p.Limits.RPS = *c.Limits.RPS
		}
		if c.Limits.Burst != nil {
			p.Limits.Burst = *c.Limits.Burst
		}
		if c.Limits.MaxRows != nil {
			v := *c.Limits.MaxRows
			p.Limits.MaxRows = &v
		}
		if c.Limits.QueryCount != nil {
			p.Limits.Quota = &packages.Quota{QueryCount: *c.Limits.QueryCount}
		}
	}
	if c.MaxConn != nil {
		p.PoolPolicy.MaxConn = *c.MaxConn
	}
	if c.MaxMounts != nil {
		p.PoolPolicy.MaxMounts = *c.MaxMounts
	}
	return p
}

// Loader is the read seam the Resolver depends on: slug → Record (or ErrNotFound).
// The real *Store satisfies it; a fake satisfies it in unit tests so Resolve is
// provable without a live database (pgx.Rows is impractical to fake). Keeping the
// resolver's dependency this narrow is also what lets the parity path be tested
// for "never reads the store when disabled".
type Loader interface {
	Load(ctx context.Context, slug string) (Record, error)
}

// Store reads/writes public.tenant_entitlements over the control-plane pool.
type Store struct {
	db pgIface
}

// NewStore wires the Store to a Postgres pool (or any pgIface).
func NewStore(db pgIface) *Store {
	return &Store{db: db}
}

// Load fetches the entitlement row for a tenant slug. Returns ErrNotFound when no
// row exists (the parity path — the resolver then falls back to manifest.For).
func (s *Store) Load(ctx context.Context, slug string) (Record, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT tenant_id, entitlement::text, COALESCE(ceiling_plan,''), status
		   FROM public.tenant_entitlements WHERE tenant_id = $1`, slug)
	if err != nil {
		return Record{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		return Record{}, ErrNotFound
	}
	var (
		rec     Record
		entJSON string
	)
	if err := rows.Scan(&rec.TenantID, &entJSON, &rec.CeilingPlan, &rec.Status); err != nil {
		return Record{}, err
	}
	if err := json.Unmarshal([]byte(entJSON), &rec.Entitlement); err != nil {
		return Record{}, fmt.Errorf("parse stored entitlement for %q: %w", slug, err)
	}
	return rec, nil
}

// Upsert writes (idempotently) a tenant's entitlement + optional ceiling_plan +
// status. The caller is responsible for the privilege boundary: the SELF-SERVE
// path MUST have passed ValidateWithin first; the OPERATOR path may set a higher
// ceiling_plan WITHOUT the self-serve clamp (the operator is the ceiling
// authority). Either way Resolve still Clamps at read time, so a too-high row
// can never widen the effective package.
func (s *Store) Upsert(ctx context.Context, rec Record) error {
	if rec.Status == "" {
		rec.Status = "active"
	}
	entJSON, err := json.Marshal(rec.Entitlement)
	if err != nil {
		return err
	}
	var ceiling any
	if rec.CeilingPlan != "" {
		ceiling = rec.CeilingPlan
	}
	return s.db.AdminExec(ctx, `
		INSERT INTO public.tenant_entitlements (tenant_id, entitlement, ceiling_plan, status, updated_at)
		VALUES ($1, $2::jsonb, $3, $4, now())
		ON CONFLICT (tenant_id) DO UPDATE
		   SET entitlement  = EXCLUDED.entitlement,
		       ceiling_plan = EXCLUDED.ceiling_plan,
		       status       = EXCLUDED.status,
		       updated_at   = now()`,
		rec.TenantID, string(entJSON), ceiling, rec.Status)
}

// SetCeiling sets ONLY the operator ceiling_plan for a tenant, creating a row
// with an empty (inherit-everything) entitlement if none exists. Operator-only.
func (s *Store) SetCeiling(ctx context.Context, slug, ceilingPlan string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.tenant_entitlements (tenant_id, entitlement, ceiling_plan, status, updated_at)
		VALUES ($1, '{}'::jsonb, $2, 'active', now())
		ON CONFLICT (tenant_id) DO UPDATE
		   SET ceiling_plan = EXCLUDED.ceiling_plan,
		       updated_at   = now()`,
		slug, ceilingPlan)
}
