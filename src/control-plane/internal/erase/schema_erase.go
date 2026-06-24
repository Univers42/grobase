/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema_erase.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:04 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:06 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package erase

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// dropTenantSchema counts the rows across the tenant schema's BASE TABLEs then
// DROPs the schema CASCADE. The schema name comes from the single-source
// tenants.TenantSchema sanitizer (never interpolated user input — it is
// [a-z0-9_]-only and prefixed tenant_), and is double-quoted for the DDL via
// pgx.Identifier.Sanitize. A non-resolvable id (empty schema) is a hard error.
func dropTenantSchema(ctx context.Context, tx pgx.Tx, schema string) (int64, error) {
	if schema == "" {
		return 0, fmt.Errorf("erase: tenant id sanitizes to an empty schema")
	}
	total, err := countSchemaRows(ctx, tx, schema)
	if err != nil {
		return 0, err
	}
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := tx.Exec(ctx, fmt.Sprintf(`DROP SCHEMA IF EXISTS %s CASCADE`, quoted)); err != nil {
		return 0, fmt.Errorf("erase: drop schema %s: %w", quoted, err)
	}
	return total, nil
}

// countSchemaRows sums row counts across every BASE TABLE in the schema (so the
// receipt's rows_purged is an honest pre-drop total). schema is a bind param in
// the catalog query; each per-table COUNT uses a sanitized identifier.
func countSchemaRows(ctx context.Context, tx pgx.Tx, schema string) (int64, error) {
	tables, err := enumerateTables(ctx, tx,
		`SELECT table_name FROM information_schema.tables
		  WHERE table_schema = $1 AND table_type = 'BASE TABLE'
		  ORDER BY table_name`, schema)
	if err != nil {
		return 0, fmt.Errorf("erase: enumerate schema tables: %w", err)
	}
	var total int64
	for _, tbl := range tables {
		qualified := pgx.Identifier{schema, tbl}.Sanitize()
		var n int64
		if err := tx.QueryRow(ctx, fmt.Sprintf(`SELECT count(*) FROM %s`, qualified)).Scan(&n); err != nil {
			return 0, fmt.Errorf("erase: count %s: %w", qualified, err)
		}
		total += n
	}
	return total, nil
}

// enumerateTables runs a catalog query returning a single text column and
// collects it into a slice (the table-name enumeration shared by the schema and
// shared-rls destruction paths). The query and its args are passed verbatim.
func enumerateTables(ctx context.Context, tx pgx.Tx, query string, args ...any) ([]string, error) {
	rows, err := tx.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tables []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		tables = append(tables, t)
	}
	return tables, rows.Err()
}
