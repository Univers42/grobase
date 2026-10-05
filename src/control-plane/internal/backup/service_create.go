/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_create.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:12 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:13 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"context"
	"fmt"
	"io"
)

// insertPending records a new backup row in 'pending' state and returns its id.
// tenant_id and mount are bind params; an empty mount stores NULL.
func (s *Service) insertPending(ctx context.Context, tenantID, mount, iso string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`INSERT INTO public.tenant_backups (tenant_id, mount, isolation, engine, location, status)
		 VALUES ($1, NULLIF($2,''), $3, 'postgresql', '', 'pending')
		 RETURNING id::text`, tenantID, mount, iso)
	if err != nil {
		return "", fmt.Errorf("backup: insert ledger row: %w", err)
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", fmt.Errorf("backup: insert ledger row: %w", rerr)
		}
		return "", fmt.Errorf("backup: insert ledger row returned no id")
	}
	var id string
	if err := rows.Scan(&id); err != nil {
		return "", fmt.Errorf("backup: scan inserted id: %w", err)
	}
	return id, nil
}

// CreateBackup performs a logical export of one tenant's data and records it.
// Flow: resolve+guard isolation -> INSERT status='pending' -> extract->Upload ->
// UPDATE status='completed' (size/sha256) or 'failed' (error_message). Returns
// the backup id. tenant_id is always a bind param.
func (s *Service) CreateBackup(ctx context.Context, tenantID, mount string) (string, error) {
	iso, dsn, err := s.isolationFor(ctx, tenantID, mount)
	if err != nil {
		return "", err
	}
	if err := guardIsolation(iso); err != nil {
		return "", err
	}
	backupID, err := s.insertPending(ctx, tenantID, mount, iso)
	if err != nil {
		return "", err
	}
	key := artifactKey(tenantID, backupID, s.seal.sealing())
	location, size, sha, xerr := s.extractTo(ctx, iso, tenantID, dsn, key)
	if xerr != nil {
		s.markFailed(ctx, backupID, xerr)
		return backupID, xerr
	}
	return backupID, s.markCompleted(ctx, backupID, location, size, sha)
}

// markFailed flips a backup ledger row to 'failed' with the error message (its
// own failure is intentionally swallowed — the caller already returns xerr).
func (s *Service) markFailed(ctx context.Context, backupID string, cause error) {
	_ = s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='failed', error_message=$2 WHERE id=$1`,
		backupID, cause.Error())
}

// markCompleted finalizes a backup ledger row with its location/size/sha.
func (s *Service) markCompleted(ctx context.Context, backupID, location string, size int64, sha string) error {
	if err := s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups
		    SET status='completed', location=$2, size_bytes=$3, sha256=$4, completed_at=now()
		  WHERE id=$1`, backupID, location, size, sha); err != nil {
		return fmt.Errorf("backup: finalize ledger row: %w", err)
	}
	return nil
}

// errUploadEnded unblocks the extract goroutine once Upload has returned.
const errUploadEnded backupErr = "backup: artifact upload ended"

// extractTo streams the tenant's export, sealed when recipients are set, into
// the store under key and returns the location/size/sha of the STORED bytes. An
// io.Pipe carries the stream (no full-artifact buffer); its read end is closed
// once Upload returns so the writer never blocks, and the writer is awaited, so
// a source failure fails the backup even when the store reported success.
func (s *Service) extractTo(ctx context.Context, iso, tenantID, dsn, key string) (string, int64, string, error) {
	pr, pw := io.Pipe()
	done := make(chan error, 1)
	go func() {
		err := s.seal.writeTo(pw, func(w io.Writer) error { return s.extract(ctx, iso, tenantID, dsn, w) })
		_ = pw.CloseWithError(err)
		done <- err
	}()
	location, size, sha, uerr := s.store.Upload(ctx, key, pr)
	_ = pr.CloseWithError(errUploadEnded)
	werr := <-done
	if uerr != nil {
		return "", 0, "", uerr
	}
	if werr != nil {
		return "", 0, "", werr
	}
	return location, size, sha, nil
}

// extract writes the export for the tenant's isolation model to w.
func (s *Service) extract(ctx context.Context, iso, tenantID, dsn string, w io.Writer) error {
	switch iso {
	case "schema_per_tenant":
		schema := s.schemaFor(tenantID)
		if schema == "" {
			return fmt.Errorf("backup: tenant id %q sanitizes to empty schema", tenantID)
		}
		return extractSchema(ctx, s.db, schema, w)
	case "db_per_tenant":
		if dsn == "" {
			return fmt.Errorf("backup: db_per_tenant requires a resolved DSN (no resolver wired)")
		}
		return extractDatabase(ctx, dsn, w)
	default:
		return ErrIsolationDeferred
	}
}
