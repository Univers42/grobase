package tenants

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// selectTenant is the canonical SELECT projection (UUID + slug + everything).
const selectTenant = `
  SELECT id::text AS uuid, slug, name, status, plan, owner_user_id, metadata::text,
         created_at::text, updated_at::text
    FROM public.tenants`

// insertTenant inserts a tenant row and returns the canonical projection.
const insertTenant = `
	WITH inserted AS (
	  INSERT INTO public.tenants (slug, name, plan, owner_user_id, metadata)
	  VALUES ($1, $2, $3, NULLIF($4,''), $5::jsonb)
	  RETURNING id, slug, name, status, plan, owner_user_id, metadata, created_at, updated_at
	)
	SELECT id::text, slug, name, status, plan, owner_user_id, metadata::text,
	       created_at::text, updated_at::text FROM inserted`

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
	row, err := s.queryOne(ctx, insertTenant,
		req.ID, req.Name, plan, req.OwnerUserID, string(metaJSON))
	if err != nil {
		return Tenant{}, mapUniqueViolation(err)
	}
	var t Tenant
	if err := scanTenant(row, &t); err != nil {
		return Tenant{}, mapUniqueViolation(err)
	}
	return t, nil
}

// mapUniqueViolation collapses a Postgres 23505 to ErrConflict, passing other
// errors through unchanged. pgx may surface the violation either on query or on
// scan (CTE INSERT...RETURNING), so both call sites route through here.
func mapUniqueViolation(err error) error {
	if pg.IsUniqueViolation(err) {
		return ErrConflict
	}
	return err
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
