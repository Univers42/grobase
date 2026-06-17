package tenants

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// ErrNotFound is returned when a tenant or key row doesn't exist.
var ErrNotFound = errors.New("tenant not found")

// ErrConflict is returned on (tenant_id) or (tenant_id, key name) uniqueness violation.
var ErrConflict = errors.New("tenant already exists")

// isUniqueViolation reports whether err is a Postgres 23505 unique-constraint
// violation. pgx may surface this either when the query executes OR later when
// the row is scanned (CTE INSERT...RETURNING), so every INSERT path must check
// it in *both* places — otherwise a duplicate leaks out as a raw 500 instead of
// a clean conflict, which broke Bootstrap idempotency.

// Service implements tenant lifecycle CRUD + key issuance.
type Service struct {
	db        *shared.Postgres
	log       *slog.Logger
	adapter   *AdapterRegistry           // optional; enables mount reconciliation in Provision
	dataPlane *DataPlane                 // optional; enables schema_per_tenant schema creation
	perm      provision.PermissionEngine // optional; the single ABAC role/policy seam
	verifyC   *verifyCache               // B4-verify: Argon2-only-on-first-seen fast path
}

// NewService wires the DB pool. The PermissionEngine seam defaults to the
// SQL backend over the same admin pool (no HTTP decide), so seedDefaultRole has
// exactly one role implementation. SetPermissionEngine can override it.
func NewService(db *shared.Postgres, log *slog.Logger) *Service {
	return &Service{db: db, log: log, perm: provision.NewSQLBackend(db, "", ""), verifyC: newVerifyCache()}
}

// SetPermissionEngine overrides the ABAC seam (e.g. to enable HTTP self-verify).
func (s *Service) SetPermissionEngine(p provision.PermissionEngine) { s.perm = p }

// SetAdapterRegistry wires the adapter-registry client used by Provision to
// register tenant data mounts. Optional — without it Provision still bootstraps
// the tenant but reports each requested mount as an error.
func (s *Service) SetAdapterRegistry(ar *AdapterRegistry) {
	s.adapter = ar
}

// SetDataPlane wires the Rust data-plane client used by Provision to create the
// per-tenant schema for schema_per_tenant mounts. Optional.
func (s *Service) SetDataPlane(dp *DataPlane) {
	s.dataPlane = dp
}

// AdapterClient returns the wired adapter-registry client (or nil if none). The
// dynamic-builder API (MountBuilder) reuses it for caller-scoped mount CRUD,
// rather than constructing a second client — one source of the adapter-registry
// URL + service token.
func (s *Service) AdapterClient() *AdapterRegistry { return s.adapter }

// EnsureSchema checks migration 032 has been applied, then idempotently widens
// the plan CHECK constraint to the current package manifest (migration 035 /
// F1) — self-healing at boot, the same pattern adapter-registry uses for the
// tenant_databases isolation CHECK. Migration 005 pinned the constraint at
// ('free','pro','enterprise'), so without this a plan PATCH to a real tier key
// (nano/basic/essential/max) 500s and PACKAGE_ENFORCEMENT cannot be used.
func (s *Service) EnsureSchema(ctx context.Context) error {
	const q = `SELECT 1 FROM information_schema.tables
	            WHERE table_schema='public' AND table_name='tenants'`
	rows, err := s.db.AdminQuery(ctx, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return errors.New("public.tenants missing — run migration 032_tenants.sql")
	}
	rows.Close() // free the pooled conn before the ALTERs below (defer is a no-op then)

	// Additive + idempotent. Existing rows (free/pro/enterprise, or NULL) all
	// satisfy the widened set, so the ADD never fails on legacy data. Logged,
	// not fatal: a stale constraint degrades tiering, it doesn't stop serving.
	if err := s.db.AdminExec(ctx,
		`ALTER TABLE public.tenants DROP CONSTRAINT IF EXISTS tenants_plan_check`); err != nil {
		s.log.Warn("drop stale tenants_plan_check failed (continuing)", "error", err)
	} else if err := s.db.AdminExec(ctx,
		`ALTER TABLE public.tenants ADD CONSTRAINT tenants_plan_check
		   CHECK (plan IN ('nano','basic','essential','pro','max','free','enterprise'))`); err != nil {
		s.log.Warn("widen tenants_plan_check failed (continuing)", "error", err)
	}
	return nil
}

// selectTenant is the canonical SELECT projection (UUID + slug + everything).
const selectTenant = `
  SELECT id::text AS uuid, slug, name, status, plan, owner_user_id, metadata::text,
         created_at::text, updated_at::text
    FROM public.tenants`

// Create inserts a tenant row keyed by slug. Uses the admin pool because the
// caller has no tenant context yet (chicken-and-egg).
func (s *Service) Create(ctx context.Context, req CreateTenantRequest) (Tenant, error) {
	meta := req.Metadata
	if meta == nil {
		meta = map[string]any{}
	}
	metaJSON, _ := json.Marshal(meta)
	plan := req.Plan
	if plan == "" {
		plan = "free"
	}

	var t Tenant
	row, err := s.queryOne(ctx, `
		WITH inserted AS (
		  INSERT INTO public.tenants (slug, name, plan, owner_user_id, metadata)
		  VALUES ($1, $2, $3, NULLIF($4,''), $5::jsonb)
		  RETURNING id, slug, name, status, plan, owner_user_id, metadata, created_at, updated_at
		)
		SELECT id::text, slug, name, status, plan, owner_user_id, metadata::text,
		       created_at::text, updated_at::text FROM inserted`,
		req.ID, req.Name, plan, req.OwnerUserID, string(metaJSON))
	if err != nil {
		if shared.IsUniqueViolation(err) {
			return Tenant{}, ErrConflict
		}
		return Tenant{}, err
	}
	if err := scanTenant(row, &t); err != nil {
		if shared.IsUniqueViolation(err) {
			return Tenant{}, ErrConflict
		}
		return Tenant{}, err
	}
	return t, nil
}

// FindOne fetches a tenant by its canonical slug OR its internal UUID.
//
// Canonical convention: the SLUG is the tenant identifier across the product
// surface (api-key VerifyKey returns it, provision scopes mounts by it, the
// query path resolves by it). The UUID is the internal primary key (FK target).
// Accepting both here means admin/control tooling can address a tenant by either
// form without a 404 — a slug never matches `id::text` and vice versa, so the
// OR is unambiguous.
func (s *Service) FindOne(ctx context.Context, slug string) (Tenant, error) {
	var t Tenant
	row, err := s.queryOne(ctx, selectTenant+` WHERE slug = $1 OR id::text = $1`, slug)
	if err != nil {
		return Tenant{}, err
	}
	if err := scanTenant(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Tenant{}, ErrNotFound
		}
		return Tenant{}, err
	}
	return t, nil
}

// List returns active tenants. Admin-only endpoint (no tenant filter).
func (s *Service) List(ctx context.Context) ([]Tenant, error) {
	rows, err := s.db.AdminQuery(ctx, selectTenant+`
		 WHERE status <> 'deleted'
		 ORDER BY created_at DESC
		 LIMIT 500`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Tenant, 0)
	for rows.Next() {
		var t Tenant
		if err := scanTenant(rows, &t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// Update mutates the fields present in the request, keyed by slug.
func (s *Service) Update(ctx context.Context, slug string, req UpdateTenantRequest) (Tenant, error) {
	var metaArg any
	if req.Metadata != nil {
		b, _ := json.Marshal(req.Metadata)
		metaArg = string(b)
	}
	row, err := s.queryOne(ctx, `
		WITH updated AS (
		  UPDATE public.tenants
		     SET name     = COALESCE($2, name),
		         plan     = COALESCE($3, plan),
		         status   = COALESCE($4, status),
		         metadata = COALESCE($5::jsonb, metadata)
		   WHERE slug = $1
		   RETURNING id, slug, name, status, plan, owner_user_id, metadata, created_at, updated_at
		)
		SELECT id::text, slug, name, status, plan, owner_user_id, metadata::text,
		       created_at::text, updated_at::text FROM updated`,
		slug, req.Name, req.Plan, req.Status, metaArg)
	if err != nil {
		return Tenant{}, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Tenant{}, ErrNotFound
		}
		return Tenant{}, err
	}
	return t, nil
}

// SoftDelete sets status='deleted'. Keyed by slug.
func (s *Service) SoftDelete(ctx context.Context, slug string) error {
	tag, err := s.exec(ctx,
		`UPDATE public.tenants SET status='deleted' WHERE slug=$1 AND status<>'deleted'`,
		slug)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
