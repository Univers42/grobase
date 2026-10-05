/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_restore.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:17 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"context"
	"fmt"
	"strings"
)

// ListBackups returns the tenant's backups, most-recent-first. tenant_id is a
// bind param; RLS is a second wall for the self-serve read path.
func (s *Service) ListBackups(ctx context.Context, tenantID string) ([]BackupRow, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT id::text, tenant_id, COALESCE(mount,''), isolation, engine, status,
		        size_bytes, COALESCE(sha256,''), created_at::text
		   FROM public.tenant_backups
		  WHERE tenant_id = $1
		  ORDER BY created_at DESC`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BackupRow
	for rows.Next() {
		var b BackupRow
		if err := rows.Scan(&b.ID, &b.TenantID, &b.Mount, &b.Isolation, &b.Engine,
			&b.Status, &b.SizeBytes, &b.SHA256, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// Restore restores a backup into the OWNING tenant only. It loads the row by
// (id, tenant_id) — the load-bearing caller==owner check — BEFORE any DDL; a
// backup id that is not the caller's (or does not exist) is indistinguishable and
// yields an empty result -> ErrNotOwned (403/404), with no DDL having run. It then
// guards isolation, downloads the artifact, and replays into A's OWN schema/db.
// Status flips restoring->restored (or 'failed').
func (s *Service) Restore(ctx context.Context, tenantID, backupID string) error {
	row, found, err := s.loadRestoreRow(ctx, tenantID, backupID)
	if err != nil {
		return err
	}
	if !found {
		return ErrNotOwned
	}
	if err := guardIsolation(row.iso); err != nil {
		return err
	}
	return s.runRestore(ctx, tenantID, backupID, row)
}

// runRestore performs the DDL half of a restore once the caller==owner + isolation
// gates have passed. The artifact is verified BEFORE the ledger status moves, so
// a refused restore leaves a good backup 'completed'; only a failed replay marks
// it 'failed'.
func (s *Service) runRestore(ctx context.Context, tenantID, backupID string, row restoreRow) error {
	apply, body, err := s.prepareRestore(ctx, tenantID, backupID, row)
	if err != nil {
		return err
	}
	if err := s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='restoring' WHERE id=$1 AND tenant_id=$2`,
		backupID, tenantID); err != nil {
		return err
	}
	if err := apply(ctx, body); err != nil {
		s.markFailed(ctx, backupID, err)
		return err
	}
	return s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='restored', completed_at=now() WHERE id=$1 AND tenant_id=$2`,
		backupID, tenantID)
}

// prepareRestore resolves the tenant's restore scope (schema, DSN) and fetches
// the artifact verified against the ledger. It writes nothing.
func (s *Service) prepareRestore(ctx context.Context, tenantID, backupID string, row restoreRow) (func(context.Context, []byte) error, []byte, error) {
	_, dsn, err := s.isolationFor(ctx, tenantID, row.mount)
	if err != nil {
		return nil, nil, err
	}
	apply, err := s.restorer(row.iso, tenantID, dsn)
	if err != nil {
		return nil, nil, err
	}
	body, err := s.fetchVerified(ctx, artifactKey(tenantID, backupID, row.sealed()), row)
	if err != nil {
		return nil, nil, err
	}
	return apply, body, nil
}

// restoreRow is the ledger slice a restore needs: isolation, mount, and the
// location, size and sha256 of the stored artifact.
type restoreRow struct {
	iso, mount, location, sha string
	size                      int64
}

// sealed reports whether the ledger records the artifact as age-sealed.
func (r restoreRow) sealed() bool { return strings.HasSuffix(r.location, sealedSuffix) }

// loadRestoreRow fetches a backup's restore ledger slice by (id, tenant_id) —
// the load-bearing caller==owner bind. found=false means the row is not the
// caller's (or does not exist), which Restore maps to ErrNotOwned BEFORE any DDL.
func (s *Service) loadRestoreRow(ctx context.Context, tenantID, backupID string) (restoreRow, bool, error) {
	var row restoreRow
	rows, err := s.db.AdminQuery(ctx,
		`SELECT isolation, COALESCE(mount,''), location, COALESCE(sha256,''), size_bytes
		   FROM public.tenant_backups
		  WHERE id = $1 AND tenant_id = $2`, backupID, tenantID)
	if err != nil {
		return row, false, fmt.Errorf("backup: load row: %w", err)
	}
	defer rows.Close()
	found := rows.Next()
	if found {
		if err := rows.Scan(&row.iso, &row.mount, &row.location, &row.sha, &row.size); err != nil {
			return row, false, fmt.Errorf("backup: scan row: %w", err)
		}
	}
	if err := rows.Err(); err != nil {
		return row, false, fmt.Errorf("backup: load row: %w", err)
	}
	return row, found, nil
}
