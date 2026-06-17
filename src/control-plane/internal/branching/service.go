package branching

import (
	"context"
	"errors"
	"log/slog"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// ErrIsolationDeferred is returned when a branch is requested for an isolation
// model DB branching does NOT support: shared_rls (no per-tenant schema to clone),
// db_per_tenant (needs the DSN resolver, B6b-style) and tenant_owned (external
// DB). The handler maps it to 400. The deferral is also enforced structurally by
// the 055 CHECK (only schema_per_tenant can be inserted). Mirrors
// export.ErrIsolationDeferred / erase.ErrUnsupportedScope.
var ErrIsolationDeferred = errors.New("isolation not supported for branching (deferred)")

// ErrNoMount is returned when the tenant has no registered mount to branch.
var ErrNoMount = errors.New("tenant has no registered data mount")

// ErrNotFound is returned when a branch id is not the caller's (or unknown). The
// handler maps it to 404 — the load-bearing caller==owner check (the lookup binds
// id AND tenant_id, so a foreign or missing id is indistinguishable → 404).
var ErrNotFound = errors.New("branch not found")

// ErrBranchExists is returned when a tenant already has a branch with that name
// (UNIQUE(tenant_id, branch_name)). The handler maps it to 409.
var ErrBranchExists = errors.New("a branch with that name already exists")

// Service orchestrates per-tenant DB BRANCHING over the shared control-plane
// Postgres (the tenant_branches ledger + the schema clone). It reuses the SAME
// data scoping the B6 backup + D4.3 export + D4.4 erase services use
// (tenants.TenantSchema for the per-tenant schema) so a branch only ever clones
// ONE tenant's own schema.
type Service struct {
	db  *shared.Postgres
	log *slog.Logger
}

// NewService builds the branching service.
func NewService(db *shared.Postgres, log *slog.Logger) *Service {
	return &Service{db: db, log: log}
}

// isolationFor resolves the isolation model for the tenant from
// public.tenant_databases (tenant_id ALWAYS a bind param — the cross-tenant wall).
// An empty mount means whole-tenant (first mount); a named mount narrows the
// lookup. Returns ErrNoMount when there is no row. Mirrors export.isolationFor /
// erase.scopeFor.
func (s *Service) isolationFor(ctx context.Context, tenantID, mount string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT isolation FROM public.tenant_databases
		  WHERE tenant_id = $1 AND ($2 = '' OR name = $2)
		  ORDER BY created_at LIMIT 1`, tenantID, mount)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", rerr
		}
		return "", ErrNoMount
	}
	var iso string
	if err := rows.Scan(&iso); err != nil {
		return "", err
	}
	return iso, nil
}

// guardIsolation rejects the isolation models DB branching does not support. Only
// schema_per_tenant is branchable in the MVP (it clones a schema).
func guardIsolation(iso string) error {
	if iso == "schema_per_tenant" {
		return nil
	}
	return ErrIsolationDeferred
}

// CreateBranch clones a schema_per_tenant mount into a fresh branch schema and
// records it. Flow: validate+normalize the branch name (the SQL-identifier
// injection wall) -> resolve+guard isolation -> resolve the parent schema ->
// INSERT status='pending' -> clone (CREATE SCHEMA + per-table LIKE/INSERT, one tx)
// -> UPDATE status='completed' (counts) or 'failed'. Returns the branch row.
//
// tenant_id is always a bind param and the parent schema is the tenant's OWN
// schema (tenants.TenantSchema), so a branch can NEVER clone another tenant's
// data. A deferred isolation model is rejected 400 BEFORE any work.
func (s *Service) CreateBranch(ctx context.Context, tenantID, mount, rawName string) (BranchRow, error) {
	branchName, err := sanitizeBranchName(rawName)
	if err != nil {
		return BranchRow{}, err
	}

	iso, err := s.isolationFor(ctx, tenantID, mount)
	if err != nil {
		return BranchRow{}, err
	}
	if err := guardIsolation(iso); err != nil {
		return BranchRow{}, err
	}

	parentSchema, err := resolveParentSchema(tenantID)
	if err != nil {
		return BranchRow{}, err
	}
	bSchema := branchSchema(parentSchema, branchName)

	branchID, err := s.insertPending(ctx, tenantID, mount, branchName, bSchema, iso)
	if err != nil {
		// A UNIQUE(tenant_id, branch_name) collision is a 409, not a 500.
		if isUniqueViolation(err) {
			return BranchRow{}, ErrBranchExists
		}
		return BranchRow{}, err
	}

	tableCount, rowCount, cerr := cloneSchema(ctx, s.db, parentSchema, bSchema)
	if cerr != nil {
		s.markFailed(ctx, branchID, cerr.Error())
		// Best-effort cleanup of a partial schema (the clone tx rolls back, but a
		// stray empty schema from a CREATE-then-fail path is dropped here too).
		_ = dropSchema(ctx, s.db, bSchema)
		return BranchRow{}, cerr
	}

	if err := s.markCompleted(ctx, branchID, tableCount, rowCount); err != nil {
		return BranchRow{}, err
	}

	return loadBranch(ctx, s.db, tenantID, branchID)
}

// ListBranches returns the tenant's branches, most-recent-first. tenant_id is a
// bind param; a non-admin caller is additionally walled by RLS.
func (s *Service) ListBranches(ctx context.Context, tenantID string) ([]BranchRow, error) {
	return listBranches(ctx, s.db, tenantID)
}

// DropBranch drops a branch's schema (CASCADE) and deletes its ledger row, AFTER
// verifying the branch id belongs to the requesting tenant (the load-bearing
// caller==owner check: loadBranch binds id AND tenant_id, so a foreign or unknown
// id yields ErrNotFound — a caller can never drop another tenant's branch).
func (s *Service) DropBranch(ctx context.Context, tenantID, branchID string) error {
	b, err := loadBranch(ctx, s.db, tenantID, branchID)
	if err != nil {
		return err
	}
	if err := dropSchema(ctx, s.db, b.BranchSchema); err != nil {
		return err
	}
	return deleteBranchRow(ctx, s.db, tenantID, branchID)
}

// isUniqueViolation reports whether err is a Postgres unique_violation (SQLSTATE
// 23505). We match on the SQLSTATE string in the error text to avoid importing a
// pgconn dependency at this boundary (the message reliably carries "23505" /
// "duplicate key"). Mirrors the lightweight constraint-mapping used elsewhere.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "23505") || strings.Contains(msg, "duplicate key")
}
