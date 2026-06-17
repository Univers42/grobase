package branching

import (
	"context"
	"fmt"
)

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
