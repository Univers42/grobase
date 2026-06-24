/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:51:35 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:37 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package orgs

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// store.go — low-level SQL helpers (mirror tenants.Service.queryOne/exec/singleRow).

// exec runs a write over the admin pool and returns its command tag. It drains
// the (empty) result set so the CommandTag is populated before reading RowsAffected.
func (s *Service) exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return pgconn.CommandTag{}, err
	}
	for rows.Next() {
	}
	return rows.CommandTag(), rows.Err()
}

func scanOrg(row interface{ Scan(...any) error }, o *Org) error {
	var metaJSON string
	if err := row.Scan(&o.ID, &o.Slug, &o.Name, &o.Plan, &o.Status, &metaJSON,
		&o.CreatedBy, &o.CreatedAt, &o.UpdatedAt); err != nil {
		return err
	}
	o.Metadata = map[string]any{}
	if metaJSON != "" {
		_ = json.Unmarshal([]byte(metaJSON), &o.Metadata)
	}
	return nil
}

// singleRow lets a multi-row pgx.Rows behave like a single pgx.Row, returning
// pgx.ErrNoRows when the cursor is empty (mirrors tenants.singleRow).
type singleRow struct {
	rows pgx.Rows
}

func (s *singleRow) Scan(dest ...any) error {
	defer s.rows.Close()
	if !s.rows.Next() {
		if err := s.rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return s.rows.Scan(dest...)
}
