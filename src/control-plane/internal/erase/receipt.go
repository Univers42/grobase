package erase

import (
	"context"
	"fmt"
)

// scopeFor resolves the tenant's isolation model from public.tenant_databases.
// tenant_id is ALWAYS a bind param (the cross-tenant wall). When the tenant has
// multiple mounts they must share one isolation model for a whole-tenant erase;
// the first row's isolation is authoritative (the MVP scopes whole-tenant erase).
func (s *Service) scopeFor(ctx context.Context, tenantID string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT isolation FROM public.tenant_databases
		  WHERE tenant_id = $1 ORDER BY created_at LIMIT 1`, tenantID)
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

// insertPending records a pending erasure_receipts row and returns its id.
// tenant_id, requested_by and scope are bind params.
func (s *Service) insertPending(ctx context.Context, tenantID, requestedBy, scope string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`INSERT INTO public.erasure_receipts (tenant_id, requested_by, scope, status)
		 VALUES ($1, $2, $3, 'pending')
		 RETURNING id::text`, tenantID, requestedBy, scope)
	if err != nil {
		return "", fmt.Errorf("erase: insert receipt: %w", err)
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", fmt.Errorf("erase: insert receipt: %w", rerr)
		}
		return "", fmt.Errorf("erase: insert receipt returned no id")
	}
	var id string
	if err := rows.Scan(&id); err != nil {
		return "", fmt.Errorf("erase: scan receipt id: %w", err)
	}
	return id, nil
}

// markFailed flips the pending receipt to 'failed' with the destruction error
// (best-effort: nothing was committed, so an update hiccup just loses the note).
func (s *Service) markFailed(ctx context.Context, receiptID string, derr error) {
	_ = s.db.AdminExec(ctx,
		`UPDATE public.erasure_receipts SET status='failed', error_message=$2 WHERE id=$1`,
		receiptID, derr.Error())
}

// markTenantDeleted soft-marks the tenant entity deleted (the data is gone; the
// entity must not keep serving). Best-effort: the data destruction already
// succeeded, so a status-flip hiccup must not flip the receipt to failed.
func (s *Service) markTenantDeleted(ctx context.Context, tenantID string) {
	if err := s.db.AdminExec(ctx,
		`UPDATE public.tenants SET status='deleted' WHERE slug=$1`, tenantID); err != nil {
		s.log.Warn("erase: mark tenant deleted failed (data already destroyed)", "tenant", tenantID, "err", err)
	}
}

// finalizeReceipt records the completed outcome on the erasure_receipts ledger.
func (s *Service) finalizeReceipt(ctx context.Context, receiptID string, rows, keys, auditSeq int64) error {
	if err := s.db.AdminExec(ctx,
		`UPDATE public.erasure_receipts
		    SET status='completed', completed_at=now(),
		        rows_purged=$2, keys_revoked=$3, audit_seq=$4
		  WHERE id=$1`, receiptID, rows, keys, auditSeq); err != nil {
		return fmt.Errorf("erase: finalize receipt: %w", err)
	}
	return nil
}
