/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   read.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:32 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:34 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package export

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/jackc/pgx/v5"
)

// ExportRow is one ledger row (the ListExports element + the export response).
type ExportRow struct {
	ID         string          `json:"id"`
	TenantID   string          `json:"tenant_id"`
	Mount      string          `json:"mount,omitempty"`
	Isolation  string          `json:"isolation"`
	Engine     string          `json:"engine"`
	Format     string          `json:"format"`
	Status     string          `json:"status"`
	Location   string          `json:"location,omitempty"`
	TableCount int             `json:"table_count"`
	RowCount   int64           `json:"row_count"`
	SizeBytes  int64           `json:"size_bytes"`
	SHA256     string          `json:"sha256,omitempty"`
	Manifest   json.RawMessage `json:"manifest,omitempty"`
	CreatedAt  string          `json:"created_at"`
}

// ListExports returns the tenant's exports, most-recent-first. tenant_id is a
// bind param; RLS is a second wall for the self-serve read path.
func (s *Service) ListExports(ctx context.Context, tenantID string) ([]ExportRow, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT id::text, tenant_id, COALESCE(mount,''), isolation, engine, format, status,
		        location, table_count, row_count, size_bytes, COALESCE(sha256,''),
		        manifest, created_at::text
		   FROM public.tenant_exports
		  WHERE tenant_id = $1
		  ORDER BY created_at DESC`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ExportRow
	for rows.Next() {
		e, serr := scanExportRow(rows)
		if serr != nil {
			return nil, serr
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// scanExportRow reads one tenant_exports row into an ExportRow, attaching the
// raw manifest JSON only when present.
func scanExportRow(rows pgx.Rows) (ExportRow, error) {
	var e ExportRow
	var man []byte
	if err := rows.Scan(&e.ID, &e.TenantID, &e.Mount, &e.Isolation, &e.Engine, &e.Format,
		&e.Status, &e.Location, &e.TableCount, &e.RowCount, &e.SizeBytes, &e.SHA256,
		&man, &e.CreatedAt); err != nil {
		return ExportRow{}, err
	}
	if len(man) > 0 {
		e.Manifest = json.RawMessage(man)
	}
	return e, nil
}

// Download streams a completed export bundle to w, AFTER verifying the export id
// belongs to the requesting tenant (the load-bearing caller==owner check: the
// lookup binds id AND tenant_id, so an id that is not the caller's — or does not
// exist — yields ErrNotFound, never another tenant's bundle). Used by the
// admin + self download routes so a tenant gets the actual portable file, not
// just the ledger row.
func (s *Service) Download(ctx context.Context, tenantID, exportID string, w io.Writer) error {
	status, err := s.ownedExportStatus(ctx, tenantID, exportID)
	if err != nil {
		return err
	}
	if status != "completed" {
		return fmt.Errorf("export %s is not completed (status=%s)", exportID, status)
	}
	key := tenantID + "/" + exportID
	return s.store.Download(ctx, key, w)
}

// ownedExportStatus returns the status of {exportID} ONLY when it belongs to
// {tenantID} (id AND tenant_id are bound). An id that is not the caller's — or
// does not exist — is indistinguishable -> ErrNotFound (load-bearing
// caller==owner check; no bytes are ever streamed for it).
func (s *Service) ownedExportStatus(ctx context.Context, tenantID, exportID string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT status FROM public.tenant_exports
		  WHERE id = $1 AND tenant_id = $2`, exportID, tenantID)
	if err != nil {
		return "", fmt.Errorf("export: load row: %w", err)
	}
	defer rows.Close()
	found := rows.Next()
	var status string
	if found {
		if serr := rows.Scan(&status); serr != nil {
			return "", serr
		}
	}
	if rerr := rows.Err(); rerr != nil {
		return "", rerr
	}
	if !found {
		return "", ErrNotFound
	}
	return status, nil
}
