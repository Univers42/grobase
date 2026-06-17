package branching

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

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
	branchName, parentSchema, iso, err := s.resolveBranchTarget(ctx, tenantID, mount, rawName)
	if err != nil {
		return BranchRow{}, err
	}
	bSchema := branchSchema(parentSchema, branchName)
	branchID, err := s.insertPending(ctx, tenantID, mount, branchName, bSchema, iso)
	if err != nil {
		// A UNIQUE(tenant_id, branch_name) collision is a 409, not a 500.
		if shared.IsUniqueViolation(err) {
			return BranchRow{}, ErrBranchExists
		}
		return BranchRow{}, err
	}
	if err := s.cloneAndFinalize(ctx, branchID, parentSchema, bSchema); err != nil {
		return BranchRow{}, err
	}
	return loadBranch(ctx, s.db, tenantID, branchID)
}

// resolveBranchTarget runs the pre-clone validation chain — sanitize the name (the
// SQL-identifier injection wall), resolve+guard isolation (only schema_per_tenant),
// resolve the tenant's OWN parent schema — and returns the sanitized branch name,
// parent schema, and isolation. A deferred isolation / invalid name fails here,
// BEFORE any ledger write or clone work.
func (s *Service) resolveBranchTarget(ctx context.Context, tenantID, mount, rawName string) (string, string, string, error) {
	branchName, err := sanitizeBranchName(rawName)
	if err != nil {
		return "", "", "", err
	}
	iso, err := s.isolationFor(ctx, tenantID, mount)
	if err != nil {
		return "", "", "", err
	}
	if err := guardIsolation(iso); err != nil {
		return "", "", "", err
	}
	parentSchema, err := resolveParentSchema(tenantID)
	if err != nil {
		return "", "", "", err
	}
	return branchName, parentSchema, iso, nil
}

// cloneAndFinalize clones the parent schema into bSchema, then finalizes the
// ledger row to 'completed' (counts) — or marks it 'failed' and best-effort drops
// the partial schema. Returns the clone/finalize error if any.
func (s *Service) cloneAndFinalize(ctx context.Context, branchID, parentSchema, bSchema string) error {
	tableCount, rowCount, cerr := cloneSchema(ctx, s.db, parentSchema, bSchema)
	if cerr != nil {
		s.markFailed(ctx, branchID, cerr.Error())
		// Best-effort cleanup of a partial schema (the clone tx rolls back, but a
		// stray empty schema from a CREATE-then-fail path is dropped here too).
		_ = dropSchema(ctx, s.db, bSchema)
		return cerr
	}
	return s.markCompleted(ctx, branchID, tableCount, rowCount)
}
