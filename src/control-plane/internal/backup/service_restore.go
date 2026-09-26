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
// gates have passed: flip status to 'restoring', resolve the (db_per_tenant) DSN,
// replay into the tenant's OWN scope, then finalize 'restored' (or 'failed').
func (s *Service) runRestore(ctx context.Context, tenantID, backupID string, row restoreRow) error {
	if err := s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='restoring' WHERE id=$1 AND tenant_id=$2`,
		backupID, tenantID); err != nil {
		return err
	}
	_, dsn, rerr := s.isolationFor(ctx, tenantID, row.mount)
	if rerr != nil {
		return rerr
	}
	key := tenantID + "/" + backupID
	if err := s.replayInto(ctx, row.iso, tenantID, dsn, key, row.sha); err != nil {
		s.markFailed(ctx, backupID, err)
		return err
	}
	return s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='restored', completed_at=now() WHERE id=$1 AND tenant_id=$2`,
		backupID, tenantID)
}

// restoreRow is the ledger slice a restore needs: isolation, mount and the
// sha256 of the stored artifact.
type restoreRow struct{ iso, mount, sha string }

// loadRestoreRow fetches a backup's isolation, mount and sha256 by (id, tenant_id)
// — the load-bearing caller==owner bind. found=false means the row is not the
// caller's (or does not exist), which Restore maps to ErrNotOwned BEFORE any DDL.
func (s *Service) loadRestoreRow(ctx context.Context, tenantID, backupID string) (restoreRow, bool, error) {
	var row restoreRow
	rows, err := s.db.AdminQuery(ctx,
		`SELECT isolation, COALESCE(mount,''), COALESCE(sha256,'')
		   FROM public.tenant_backups
		  WHERE id = $1 AND tenant_id = $2`, backupID, tenantID)
	if err != nil {
		return row, false, fmt.Errorf("backup: load row: %w", err)
	}
	defer rows.Close()
	found := rows.Next()
	if found {
		if err := rows.Scan(&row.iso, &row.mount, &row.sha); err != nil {
			return row, false, fmt.Errorf("backup: scan row: %w", err)
		}
	}
	if err := rows.Err(); err != nil {
		return row, false, fmt.Errorf("backup: load row: %w", err)
	}
	return row, found, nil
}

// replayInto checks the restore scope, fetches the artifact verified against
// the ledger's sha256, and replays it into the tenant's OWN schema or database.
// Nothing is written before the artifact is verified.
func (s *Service) replayInto(ctx context.Context, iso, tenantID, dsn, key, wantSHA string) error {
	apply, err := s.restorer(iso, tenantID, dsn)
	if err != nil {
		return err
	}
	body, err := s.fetchVerified(ctx, key, wantSHA)
	if err != nil {
		return err
	}
	return apply(ctx, body)
}
