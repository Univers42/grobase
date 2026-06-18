package branching

import "context"

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
