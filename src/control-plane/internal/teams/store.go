/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:29 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// store.go — low-level SQL helpers over the admin pool (mirror orgs.Service.exec /
// orgs.singleRow). Reads/writes are owner-bounded by the SQL the callers pass.

// queryRow runs a single-row query over the admin pool and returns a Scan-able row
// that yields pgx.ErrNoRows when empty (mirrors orgs.singleRow).
func (s *Service) queryRow(ctx context.Context, sql string, args ...any) rowScanner {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	return &singleRow{rows: rows, err: err}
}

// exec runs a write over the admin pool and returns its command tag (mirrors
// orgs.Service.exec — drains the empty result set so RowsAffected is populated).
func (s *Service) exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return pgconn.CommandTag{}, err
	}
	for rows.Next() {
	}
	return rows.CommandTag(), rows.Err()
}

// rowScanner is the minimal single-row read surface.
type rowScanner interface{ Scan(dest ...any) error }

// singleRow adapts a multi-row pgx.Rows to one row, returning the deferred query
// error or pgx.ErrNoRows when the cursor is empty.
type singleRow struct {
	rows pgx.Rows
	err  error
}

func (s *singleRow) Scan(dest ...any) error {
	if s.err != nil {
		return s.err
	}
	defer s.rows.Close()
	if !s.rows.Next() {
		if err := s.rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return s.rows.Scan(dest...)
}

// scanTeam reads a teams row in the canonical column order.
func scanTeam(row rowScanner, t *Team) error {
	var metaJSON string
	if err := row.Scan(&t.ID, &t.OrgID, &t.Slug, &t.Name, &metaJSON,
		&t.CreatedBy, &t.CreatedAt, &t.UpdatedAt); err != nil {
		return err
	}
	t.Metadata = map[string]any{}
	if metaJSON != "" {
		_ = json.Unmarshal([]byte(metaJSON), &t.Metadata)
	}
	return nil
}

// selectTeam is the canonical teams projection used by every team read.
const selectTeam = `
  SELECT id::text, org_id::text, slug, name, metadata::text, created_by,
         created_at::text, updated_at::text
    FROM public.teams`
