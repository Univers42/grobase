package branching

import (
	"context"
)

// ErrIsolationDeferred is returned when a branch is requested for an isolation
// model DB branching does NOT support: shared_rls (no per-tenant schema to clone),
// db_per_tenant (needs the DSN resolver, B6b-style) and tenant_owned (external
// DB). The handler maps it to 400. The deferral is also enforced structurally by
// the 055 CHECK (only schema_per_tenant can be inserted). Mirrors
// export.ErrIsolationDeferred / erase.ErrUnsupportedScope.
const ErrIsolationDeferred branchingErr = "isolation not supported for branching (deferred)"

// ErrNoMount is returned when the tenant has no registered mount to branch.
const ErrNoMount branchingErr = "tenant has no registered data mount"

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
