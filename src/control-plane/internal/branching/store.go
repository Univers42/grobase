// Package branching implements per-tenant DB BRANCHES (Track-E DB branching) —
// Supabase-parity "branches". A branch is an isolated SCHEMA-CLONE of a
// schema_per_tenant mount: the parent's tables + a full row copy, living next to
// the parent in the SAME control-plane Postgres so it is immediately queryable
// for preview/staging.
//
// It reuses the data-SCOPING the B6 backup + D4.3 export + D4.4 erase services
// share (tenants.TenantSchema for the per-tenant schema; information_schema for
// BASE TABLE discovery) but the OUTPUT is different in kind: backup/export emit an
// ARTIFACT (COPY / portable JSON) you carry elsewhere, whereas a branch is a LIVE
// schema you keep querying. The clone is done over the existing pgx pool with
// `CREATE TABLE … (LIKE … INCLUDING ALL)` + `INSERT … SELECT *` — NO pg_dump.
//
// SCOPING (strictly ONE tenant): only schema_per_tenant is branchable in the MVP
// (it clones a schema). shared_rls (no per-tenant schema), db_per_tenant (needs a
// DSN resolver, B6b-style) and tenant_owned (external DB) are DEFERRED and
// rejected 400 [ErrIsolationDeferred].
//
// The whole surface is flag-gated by DB_BRANCHING_ENABLED (default OFF); when off,
// main.go never mounts the routes, so nothing in this package ever runs and the
// public.tenant_branches table stays empty = byte-parity baseline (the same story
// as B6 / D3 / D4.3 / D4.4).
package branching

import (
	"context"
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// BranchRow is one ledger row (the ListBranches element + the create/get
// response). It is the durable record of a branch — never the live schema's data.
type BranchRow struct {
	ID           string `json:"id"`
	TenantID     string `json:"tenant_id"`
	ParentMount  string `json:"parent_mount,omitempty"`
	BranchName   string `json:"branch_name"`
	BranchSchema string `json:"branch_schema"`
	Isolation    string `json:"isolation"`
	Status       string `json:"status"`
	TableCount   int    `json:"table_count"`
	RowCount     int64  `json:"row_count"`
	CreatedAt    string `json:"created_at"`
}

// insertPending records a new branch row in 'pending' state and returns its id.
// tenant_id, parent_mount, branch_name, branch_schema, isolation are bind params;
// an empty parent_mount stores NULL. The UNIQUE(tenant_id, branch_name) makes a
// duplicate name fail at the DB (mapped to ErrBranchExists by the service).
func (s *Service) insertPending(ctx context.Context, tenantID, parentMount, branchName, branchSchema, iso string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`INSERT INTO public.tenant_branches
		   (tenant_id, parent_mount, branch_name, branch_schema, isolation, status)
		 VALUES ($1, NULLIF($2,''), $3, $4, $5, 'pending')
		 RETURNING id::text`, tenantID, parentMount, branchName, branchSchema, iso)
	if err != nil {
		return "", fmt.Errorf("branching: insert ledger row: %w", err)
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", fmt.Errorf("branching: insert ledger row: %w", rerr)
		}
		return "", fmt.Errorf("branching: insert ledger row returned no id")
	}
	var id string
	if err := rows.Scan(&id); err != nil {
		return "", fmt.Errorf("branching: scan inserted id: %w", err)
	}
	return id, nil
}

// markCompleted finalizes a branch row with the cloned table/row counts.
func (s *Service) markCompleted(ctx context.Context, branchID string, tableCount int, rowCount int64) error {
	if err := s.db.AdminExec(ctx,
		`UPDATE public.tenant_branches
		    SET status='completed', table_count=$2, row_count=$3, completed_at=now()
		  WHERE id=$1`, branchID, tableCount, rowCount); err != nil {
		return fmt.Errorf("branching: finalize ledger row: %w", err)
	}
	return nil
}

// markFailed records a failed clone with its error message (best-effort).
func (s *Service) markFailed(ctx context.Context, branchID, msg string) {
	_ = s.db.AdminExec(ctx,
		`UPDATE public.tenant_branches SET status='failed', error_message=$2 WHERE id=$1`,
		branchID, msg)
}

// listBranches returns the tenant's branches, most-recent-first. tenant_id is a
// bind param (the cross-tenant wall); RLS is a second wall for any non-admin path.
func listBranches(ctx context.Context, db *shared.Postgres, tenantID string) ([]BranchRow, error) {
	rows, err := db.AdminQuery(ctx,
		`SELECT id::text, tenant_id, COALESCE(parent_mount,''), branch_name, branch_schema,
		        isolation, status, table_count, row_count, created_at::text
		   FROM public.tenant_branches
		  WHERE tenant_id = $1
		  ORDER BY created_at DESC`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BranchRow
	for rows.Next() {
		var b BranchRow
		if err := rows.Scan(&b.ID, &b.TenantID, &b.ParentMount, &b.BranchName, &b.BranchSchema,
			&b.Isolation, &b.Status, &b.TableCount, &b.RowCount, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// loadBranch fetches one branch row by id, BOUND to tenant_id (the load-bearing
// caller==owner check: a branchId that is not the caller's — or unknown — yields
// ErrNotFound, never another tenant's branch). Returns the branch_schema (needed
// to DROP) alongside the row.
func loadBranch(ctx context.Context, db *shared.Postgres, tenantID, branchID string) (BranchRow, error) {
	rows, err := db.AdminQuery(ctx,
		`SELECT id::text, tenant_id, COALESCE(parent_mount,''), branch_name, branch_schema,
		        isolation, status, table_count, row_count, created_at::text
		   FROM public.tenant_branches
		  WHERE id = $1 AND tenant_id = $2`, branchID, tenantID)
	if err != nil {
		return BranchRow{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return BranchRow{}, rerr
		}
		return BranchRow{}, ErrNotFound
	}
	var b BranchRow
	if err := rows.Scan(&b.ID, &b.TenantID, &b.ParentMount, &b.BranchName, &b.BranchSchema,
		&b.Isolation, &b.Status, &b.TableCount, &b.RowCount, &b.CreatedAt); err != nil {
		return BranchRow{}, err
	}
	return b, nil
}

// deleteBranchRow removes the ledger row AFTER its schema has been dropped.
// tenant_id is bound so a row is only ever deleted by its owner.
func deleteBranchRow(ctx context.Context, db *shared.Postgres, tenantID, branchID string) error {
	return db.AdminExec(ctx,
		`DELETE FROM public.tenant_branches WHERE id = $1 AND tenant_id = $2`, branchID, tenantID)
}
