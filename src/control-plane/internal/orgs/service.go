package orgs

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// Service implements the org lifecycle: org CRUD, membership, role lookup, the
// last-owner guard, and the org_id stamp on a provisioned project. It speaks SQL
// over the admin pool (BYPASSRLS service_role) — the Go capability gate is the
// first wall, the RLS policies on the org tables are the second.
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool + logger.
func NewService(db *pg.Postgres, log *slog.Logger) *Service {
	return &Service{db: db, log: log}
}

// ── org CRUD ─────────────────────────────────────────────────────────────────

const selectOrg = `
  SELECT id::text, slug, name, plan, status, metadata::text, created_by,
         created_at::text, updated_at::text
    FROM public.orgs`

// CreateOrg inserts an org AND its creator's owner membership in ONE transaction
// (so an org can never exist without an owner — the break-glass anchor invariant
// holds from birth). createdBy is the GoTrue user uuid of the caller.
func (s *Service) CreateOrg(ctx context.Context, req CreateOrgRequest, createdBy string) (Org, error) {
	metaJSON, plan := normalizeOrgInput(req)
	// Acquire ONE dedicated pooled connection so the org INSERT + the owner
	// membership INSERT commit atomically (the break-glass anchor invariant).
	conn, err := s.db.AcquireConn(ctx)
	if err != nil {
		return Org{}, err
	}
	defer conn.Release()
	tx, err := conn.Begin(ctx)
	if err != nil {
		return Org{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	o, err := insertOrgWithOwner(ctx, tx, req, plan, metaJSON, createdBy)
	if err != nil {
		return Org{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Org{}, err
	}
	return o, nil
}

// normalizeOrgInput applies the CreateOrg defaults: empty metadata -> {} and an
// empty plan -> "free", returning the JSON-encoded metadata and the resolved plan.
func normalizeOrgInput(req CreateOrgRequest) (metaJSON, plan string) {
	meta := req.Metadata
	if meta == nil {
		meta = map[string]any{}
	}
	b, _ := json.Marshal(meta)
	plan = strings.TrimSpace(req.Plan)
	if plan == "" {
		plan = "free"
	}
	return string(b), plan
}

// insertOrgWithOwner runs the org INSERT + the creator's owner-membership INSERT
// inside tx (the caller commits) — the two writes that make the break-glass
// anchor invariant hold from birth.
func insertOrgWithOwner(ctx context.Context, tx pgx.Tx, req CreateOrgRequest,
	plan, metaJSON, createdBy string) (Org, error) {
	var o Org
	row := tx.QueryRow(ctx, `
		INSERT INTO public.orgs (slug, name, plan, metadata, created_by)
		VALUES ($1, $2, $3, $4::jsonb, NULLIF($5,''))
		RETURNING id::text, slug, name, plan, status, metadata::text, created_by,
		          created_at::text, updated_at::text`,
		req.Slug, req.Name, plan, metaJSON, createdBy)
	if err := scanOrg(row, &o); err != nil {
		if pg.IsUniqueViolation(err) {
			return Org{}, ErrConflict
		}
		return Org{}, err
	}
	// Atomically make the creator the first member with role=owner.
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.org_members (org_id, user_id, role, invited_by)
		VALUES ($1::uuid, $2, 'owner', $2)`,
		o.ID, createdBy); err != nil {
		return Org{}, err
	}
	return o, nil
}
