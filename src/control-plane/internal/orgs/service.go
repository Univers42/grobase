package orgs

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Service implements the org lifecycle: org CRUD, membership, role lookup, the
// last-owner guard, and the org_id stamp on a provisioned project. It speaks SQL
// over the admin pool (BYPASSRLS service_role) — the Go capability gate is the
// first wall, the RLS policies on the org tables are the second.
type Service struct {
	db  *shared.Postgres
	log *slog.Logger
}

// NewService wires the DB pool + logger.
func NewService(db *shared.Postgres, log *slog.Logger) *Service {
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
	meta := req.Metadata
	if meta == nil {
		meta = map[string]any{}
	}
	metaJSON, _ := json.Marshal(meta)
	plan := strings.TrimSpace(req.Plan)
	if plan == "" {
		plan = "free"
	}

	// Acquire ONE dedicated pooled connection so the org INSERT + the owner
	// membership INSERT commit atomically (an org can never exist without an
	// owner — the break-glass anchor invariant holds from birth).
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

	var o Org
	row := tx.QueryRow(ctx, `
		INSERT INTO public.orgs (slug, name, plan, metadata, created_by)
		VALUES ($1, $2, $3, $4::jsonb, NULLIF($5,''))
		RETURNING id::text, slug, name, plan, status, metadata::text, created_by,
		          created_at::text, updated_at::text`,
		req.Slug, req.Name, plan, string(metaJSON), createdBy)
	if err := scanOrg(row, &o); err != nil {
		if shared.IsUniqueViolation(err) {
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
	if err := tx.Commit(ctx); err != nil {
		return Org{}, err
	}
	return o, nil
}

// GetOrg fetches an org by its uuid OR slug.
func (s *Service) GetOrg(ctx context.Context, idOrSlug string) (Org, error) {
	rows, err := s.db.AdminQuery(ctx, selectOrg+` WHERE id::text = $1 OR slug = $1`, idOrSlug)
	if err != nil {
		return Org{}, err
	}
	var o Org
	if err := scanOrg(&singleRow{rows: rows}, &o); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Org{}, ErrNotFound
		}
		return Org{}, err
	}
	return o, nil
}

// ListOrgsForUser returns the orgs the user is a member of.
func (s *Service) ListOrgsForUser(ctx context.Context, userID string) ([]Org, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT o.id::text, o.slug, o.name, o.plan, o.status, o.metadata::text, o.created_by,
		       o.created_at::text, o.updated_at::text
		  FROM public.orgs o
		  JOIN public.org_members m ON m.org_id = o.id
		 WHERE m.user_id = $1 AND o.status <> 'deleted'
		 ORDER BY o.created_at DESC
		 LIMIT 500`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Org, 0)
	for rows.Next() {
		var o Org
		if err := scanOrg(rows, &o); err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// UpdateOrg mutates name/metadata, keyed by org id.
func (s *Service) UpdateOrg(ctx context.Context, orgID string, req UpdateOrgRequest) (Org, error) {
	var metaArg any
	if req.Metadata != nil {
		b, _ := json.Marshal(req.Metadata)
		metaArg = string(b)
	}
	rows, err := s.db.AdminQuery(ctx, `
		UPDATE public.orgs
		   SET name     = COALESCE($2, name),
		       metadata = COALESCE($3::jsonb, metadata),
		       updated_at = now()
		 WHERE id::text = $1
		 RETURNING id::text, slug, name, plan, status, metadata::text, created_by,
		           created_at::text, updated_at::text`,
		orgID, req.Name, metaArg)
	if err != nil {
		return Org{}, err
	}
	var o Org
	if err := scanOrg(&singleRow{rows: rows}, &o); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Org{}, ErrNotFound
		}
		return Org{}, err
	}
	return o, nil
}

// SoftDeleteOrg sets status='deleted'. ON DELETE SET NULL on tenants.org_id is
// NOT triggered by a soft-delete (the row stays), so attached projects keep their
// org_id; a hard delete (manual) would orphan them to org-less. Keyed by org id.
func (s *Service) SoftDeleteOrg(ctx context.Context, orgID string) error {
	tag, err := s.exec(ctx,
		`UPDATE public.orgs SET status='deleted', updated_at=now()
		  WHERE id::text=$1 AND status<>'deleted'`, orgID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ── membership + role lookup ─────────────────────────────────────────────────

// MemberRole resolves the caller's role within an org. ok=false means the user is
// NOT a member (the cross-org isolation primitive: a non-member can never see or
// act on an org). This is the function the capability gate calls.
func (s *Service) MemberRole(ctx context.Context, orgID, userID string) (Role, bool) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT role FROM public.org_members WHERE org_id::text=$1 AND user_id=$2`, orgID, userID)
	if err != nil {
		return "", false
	}
	defer rows.Close()
	if !rows.Next() {
		return "", false
	}
	var role string
	if err := rows.Scan(&role); err != nil {
		return "", false
	}
	return Role(role), true
}

// ListMembers returns the org's membership.
func (s *Service) ListMembers(ctx context.Context, orgID string) ([]Member, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT org_id::text, user_id, role, invited_by, created_at::text
		  FROM public.org_members WHERE org_id::text=$1 ORDER BY created_at`, orgID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Member, 0)
	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.OrgID, &m.UserID, &m.Role, &m.InvitedBy, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// AddMember upserts a (org,user)->role membership. Used by invite acceptance.
func (s *Service) AddMember(ctx context.Context, orgID, userID, role, invitedBy string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.org_members (org_id, user_id, role, invited_by)
		VALUES ($1::uuid, $2, $3, NULLIF($4,''))
		ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
		orgID, userID, role, invitedBy)
}

// SetMemberRole changes a member's role, guarded by the last-owner invariant: it
// refuses to demote the SOLE owner (ErrLastOwner). The admin-vs-owner asymmetry
// is enforced in the handler (canSetRole) before this is called.
func (s *Service) SetMemberRole(ctx context.Context, orgID, userID, newRole string) error {
	if newRole != string(RoleOwner) {
		// Demoting away from owner: block if this is the last owner.
		isOwner, owners, err := s.ownerCount(ctx, orgID, userID)
		if err != nil {
			return err
		}
		if isOwner && owners <= 1 {
			return ErrLastOwner
		}
	}
	tag, err := s.exec(ctx,
		`UPDATE public.org_members SET role=$3 WHERE org_id::text=$1 AND user_id=$2`,
		orgID, userID, newRole)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// RemoveMember deletes a membership, guarded by the last-owner invariant: it
// refuses to remove the SOLE owner (ErrLastOwner) so an org always retains a
// break-glass owner.
func (s *Service) RemoveMember(ctx context.Context, orgID, userID string) error {
	isOwner, owners, err := s.ownerCount(ctx, orgID, userID)
	if err != nil {
		return err
	}
	if isOwner && owners <= 1 {
		return ErrLastOwner
	}
	tag, err := s.exec(ctx,
		`DELETE FROM public.org_members WHERE org_id::text=$1 AND user_id=$2`, orgID, userID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ownerCount reports whether userID is an owner of the org and how many owners
// the org has in total — the inputs to the last-owner guard.
func (s *Service) ownerCount(ctx context.Context, orgID, userID string) (isOwner bool, owners int, err error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT
		  COALESCE(bool_or(user_id=$2 AND role='owner'), false) AS is_owner,
		  COUNT(*) FILTER (WHERE role='owner')                  AS owners
		FROM public.org_members WHERE org_id::text=$1`, orgID, userID)
	if err != nil {
		return false, 0, err
	}
	defer rows.Close()
	if !rows.Next() {
		return false, 0, rows.Err()
	}
	if err := rows.Scan(&isOwner, &owners); err != nil {
		return false, 0, err
	}
	return isOwner, owners, nil
}

// ── project <-> org linkage ──────────────────────────────────────────────────

// AttachProjectToOrg stamps tenants.org_id = orgID for the project slug. This is
// the ONLY org write the provision path makes — additive, AFTER the reconciler
// has run. It is read by NO request-path code (the data plane never selects it).
func (s *Service) AttachProjectToOrg(ctx context.Context, projectSlug, orgID string) error {
	return s.db.AdminExec(ctx,
		`UPDATE public.tenants SET org_id = $2::uuid WHERE slug = $1`, projectSlug, orgID)
}

// ListProjects returns the project slugs (+ name/plan/status) attached to an org.
func (s *Service) ListProjects(ctx context.Context, orgID string) ([]map[string]any, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT slug, name, plan, status FROM public.tenants
		 WHERE org_id::text=$1 AND status <> 'deleted' ORDER BY created_at DESC LIMIT 500`, orgID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]map[string]any, 0)
	for rows.Next() {
		var slug, name, plan, status string
		if err := rows.Scan(&slug, &name, &plan, &status); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"id": slug, "name": name, "plan": plan, "status": status})
	}
	return out, rows.Err()
}

// ── helpers (mirror tenants.Service.queryOne/exec/singleRow) ─────────────────

func (s *Service) exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return pgconn.CommandTag{}, err
	}
	for rows.Next() { /* drain */
	}
	return rows.CommandTag(), rows.Err()
}

func scanOrg(row interface{ Scan(...any) error }, o *Org) error {
	var metaJSON string
	if err := row.Scan(&o.ID, &o.Slug, &o.Name, &o.Plan, &o.Status, &metaJSON,
		&o.CreatedBy, &o.CreatedAt, &o.UpdatedAt); err != nil {
		return err
	}
	o.Metadata = map[string]any{}
	if metaJSON != "" {
		_ = json.Unmarshal([]byte(metaJSON), &o.Metadata)
	}
	return nil
}

// singleRow lets a multi-row pgx.Rows behave like a single pgx.Row, returning
// pgx.ErrNoRows when the cursor is empty (mirrors tenants.singleRow).
type singleRow struct {
	rows pgx.Rows
}

func (s *singleRow) Scan(dest ...any) error {
	defer s.rows.Close()
	if !s.rows.Next() {
		if err := s.rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return s.rows.Scan(dest...)
}
