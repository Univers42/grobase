package backup

import (
	"context"
	"fmt"
	"io"
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
// (id, tenant_id) — the load-bearing caller==owner check — BEFORE any DDL; an
// empty result is ErrNotOwned (403/404). It then guards isolation, downloads the
// artifact, and replays into A's OWN schema/db. Status flips restoring->restored
// (or 'failed').
func (s *Service) Restore(ctx context.Context, tenantID, backupID string) error {
	iso, mount, found, err := s.loadRestoreRow(ctx, tenantID, backupID)
	if err != nil {
		return err
	}
	if !found {
		// Load-bearing caller==owner: a backup id that is not the caller's (or
		// does not exist) is indistinguishable -> ErrNotOwned (403/404). NO DDL
		// has run at this point.
		return ErrNotOwned
	}
	if err := guardIsolation(iso); err != nil {
		return err
	}
	return s.runRestore(ctx, tenantID, backupID, iso, mount)
}

// runRestore performs the DDL half of a restore once the caller==owner + isolation
// gates have passed: flip status to 'restoring', resolve the (db_per_tenant) DSN,
// replay into the tenant's OWN scope, then finalize 'restored' (or 'failed').
func (s *Service) runRestore(ctx context.Context, tenantID, backupID, iso, mount string) error {
	if err := s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='restoring' WHERE id=$1 AND tenant_id=$2`,
		backupID, tenantID); err != nil {
		return err
	}
	_, dsn, rerr := s.isolationFor(ctx, tenantID, mount)
	if rerr != nil {
		return rerr
	}
	key := tenantID + "/" + backupID
	if err := s.replayInto(ctx, iso, tenantID, dsn, key); err != nil {
		s.markFailed(ctx, backupID, err)
		return err
	}
	return s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='restored', completed_at=now() WHERE id=$1 AND tenant_id=$2`,
		backupID, tenantID)
}

// loadRestoreRow fetches a backup's isolation+mount by (id, tenant_id) — the
// load-bearing caller==owner bind. found=false means the row is not the caller's
// (or does not exist), which Restore maps to ErrNotOwned BEFORE any DDL.
func (s *Service) loadRestoreRow(ctx context.Context, tenantID, backupID string) (iso, mount string, found bool, err error) {
	rows, qerr := s.db.AdminQuery(ctx,
		`SELECT isolation, COALESCE(mount,'')
		   FROM public.tenant_backups
		  WHERE id = $1 AND tenant_id = $2`, backupID, tenantID)
	if qerr != nil {
		return "", "", false, fmt.Errorf("backup: load row: %w", qerr)
	}
	defer rows.Close()
	if rows.Next() {
		if scanErr := rows.Scan(&iso, &mount); scanErr != nil {
			return "", "", false, fmt.Errorf("backup: scan row: %w", scanErr)
		}
		found = true
	}
	if rerr := rows.Err(); rerr != nil {
		return "", "", false, fmt.Errorf("backup: load row: %w", rerr)
	}
	return iso, mount, found, nil
}

// replayInto downloads the artifact and replays it into the tenant's OWN scope.
func (s *Service) replayInto(ctx context.Context, iso, tenantID, dsn, key string) error {
	pr, pw := io.Pipe()
	go func() { _ = pw.CloseWithError(s.store.Download(ctx, key, pw)) }()
	switch iso {
	case "schema_per_tenant":
		schema := s.schemaFor(tenantID)
		if schema == "" {
			return fmt.Errorf("backup: tenant id %q sanitizes to empty schema", tenantID)
		}
		return restoreSchema(ctx, s.db, schema, pr)
	case "db_per_tenant":
		if dsn == "" {
			return fmt.Errorf("backup: db_per_tenant restore requires a resolved DSN (no resolver wired)")
		}
		return restoreDatabase(ctx, dsn, pr)
	default:
		return ErrIsolationDeferred
	}
}
