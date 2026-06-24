/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   extract_db.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:51 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:52 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"context"
	"fmt"
	"io"

	"github.com/jackc/pgx/v5"
)

// enumerateDBSchemas lists every non-system schema in a db_per_tenant database,
// deterministically ordered, so nothing in the tenant's data is missed.
func enumerateDBSchemas(ctx context.Context, conn *pgx.Conn) ([]string, error) {
	srows, err := conn.Query(ctx,
		`SELECT schema_name FROM information_schema.schemata
		  WHERE schema_name NOT IN ('pg_catalog','information_schema')
		    AND schema_name NOT LIKE 'pg_%'
		  ORDER BY schema_name`)
	if err != nil {
		return nil, fmt.Errorf("backup: enumerate db schemas: %w", err)
	}
	defer srows.Close()
	var schemas []string
	for srows.Next() {
		var sc string
		if err := srows.Scan(&sc); err != nil {
			return nil, err
		}
		schemas = append(schemas, sc)
	}
	return schemas, srows.Err()
}

// enumerateDBTables lists the BASE TABLEs in one schema of a tenant database,
// deterministically ordered. schema is a bind parameter — never interpolated.
func enumerateDBTables(ctx context.Context, conn *pgx.Conn, schema string) ([]string, error) {
	trows, err := conn.Query(ctx,
		`SELECT table_name FROM information_schema.tables
		  WHERE table_schema = $1 AND table_type = 'BASE TABLE'
		  ORDER BY table_name`, schema)
	if err != nil {
		return nil, fmt.Errorf("backup: enumerate db tables: %w", err)
	}
	defer trows.Close()
	var tables []string
	for trows.Next() {
		var t string
		if err := trows.Scan(&t); err != nil {
			return nil, err
		}
		tables = append(tables, t)
	}
	return tables, trows.Err()
}

// copyDBSchema COPYs every BASE TABLE of one schema into w and records each as a
// schema-qualified manifest slice (the qualified name is what db restore targets).
func copyDBSchema(ctx context.Context, conn *pgx.Conn, sc string, w io.Writer, m *manifest) error {
	tables, err := enumerateDBTables(ctx, conn, sc)
	if err != nil {
		return err
	}
	for _, tbl := range tables {
		cw := &countingWriter{w: w}
		qualified := pgx.Identifier{sc, tbl}.Sanitize()
		tag, err := conn.PgConn().CopyTo(ctx, cw,
			fmt.Sprintf(`COPY (SELECT * FROM %s) TO STDOUT (FORMAT text)`, qualified))
		if err != nil {
			return fmt.Errorf("backup: COPY TO %s: %w", qualified, err)
		}
		m.Tables = append(m.Tables, tableExtract{Table: qualified, Bytes: cw.n, Rows: tag.RowsAffected()})
	}
	return nil
}
