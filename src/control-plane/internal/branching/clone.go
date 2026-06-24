/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   clone.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:52 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:53 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package branching

import (
	"context"
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// cloneSchema clones every BASE TABLE in parentSchema into branchSchema (a fresh
// schema), copying ALL rows, over the existing pgx pool — NO pg_dump. It returns
// the number of tables cloned and the total rows copied. Both schema names are
// already-sanitized identifiers (tenants.TenantSchema + sanitizeBranchName), and
// each is additionally quoted via pgx.Identifier.Sanitize() (double-belt). The
// clone runs in ONE transaction so a mid-clone failure leaves NO half-built
// schema (all-or-nothing).
func cloneSchema(ctx context.Context, db *pg.Postgres, parentSchema, branchSchemaName string) (int, int64, error) {
	conn, err := db.AcquireConn(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("branching: acquire conn: %w", err)
	}
	defer conn.Release()

	tables, err := enumerateSchemaTables(ctx, conn, parentSchema)
	if err != nil {
		return 0, 0, err
	}
	total, err := cloneInTx(ctx, conn, parentSchema, branchSchemaName, tables)
	if err != nil {
		return 0, 0, err
	}
	return len(tables), total, nil
}

// cloneInTx runs the CREATE SCHEMA + per-table clone inside ONE transaction so a
// mid-clone failure leaves NO half-built schema (all-or-nothing). Returns the
// total rows copied.
func cloneInTx(ctx context.Context, conn *pgxpool.Conn, parentSchema, branchSchemaName string, tables []string) (int64, error) {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("branching: begin clone tx: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()
	total, err := cloneTables(ctx, tx, parentSchema, branchSchemaName, tables)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("branching: commit clone tx: %w", err)
	}
	committed = true
	return total, nil
}

// cloneTables creates the branch schema then per-table replicates structure
// (LIKE … INCLUDING ALL — copies columns, defaults, constraints, indexes) plus a
// full row copy (INSERT … SELECT *) inside the open tx, returning the total rows
// copied. Both schema names are pre-sanitized and re-quoted via pgx.Identifier
// (double-belt).
func cloneTables(ctx context.Context, tx pgx.Tx, parentSchema, branchSchemaName string, tables []string) (int64, error) {
	branchQ := pgx.Identifier{branchSchemaName}.Sanitize()
	if _, err := tx.Exec(ctx, fmt.Sprintf(`CREATE SCHEMA %s`, branchQ)); err != nil {
		return 0, fmt.Errorf("branching: create branch schema %s: %w", branchSchemaName, err)
	}
	var total int64
	for _, t := range tables {
		parentT := pgx.Identifier{parentSchema, t}.Sanitize()
		branchT := pgx.Identifier{branchSchemaName, t}.Sanitize()
		if _, err := tx.Exec(ctx,
			fmt.Sprintf(`CREATE TABLE %s (LIKE %s INCLUDING ALL)`, branchT, parentT)); err != nil {
			return 0, fmt.Errorf("branching: create table %s: %w", branchT, err)
		}
		tag, err := tx.Exec(ctx, fmt.Sprintf(`INSERT INTO %s SELECT * FROM %s`, branchT, parentT))
		if err != nil {
			return 0, fmt.Errorf("branching: copy rows %s: %w", branchT, err)
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// dropSchema removes a branch's schema and everything in it (CASCADE), over the
// pool. branchSchemaName is the already-sanitized schema recorded in the ledger;
// it is re-quoted via pgx.Identifier (double-belt). `IF EXISTS` makes a re-drop a
// no-op, so dropping an already-gone branch is idempotent.
func dropSchema(ctx context.Context, db *pg.Postgres, branchSchemaName string) error {
	q := pgx.Identifier{branchSchemaName}.Sanitize()
	if err := db.AdminExec(ctx, fmt.Sprintf(`DROP SCHEMA IF EXISTS %s CASCADE`, q)); err != nil {
		return fmt.Errorf("branching: drop branch schema %s: %w", branchSchemaName, err)
	}
	return nil
}

// enumerateSchemaTables lists the BASE TABLEs in a schema, deterministically
// ordered. schema is a bind parameter in the catalog query (never interpolated);
// each returned table name is quoted by the caller via pgx.Identifier. Mirrors
// backup.enumerateTables / export.enumerateSchemaTables.
func enumerateSchemaTables(ctx context.Context, conn *pgxpool.Conn, schema string) ([]string, error) {
	rows, err := conn.Query(ctx,
		`SELECT table_name FROM information_schema.tables
		  WHERE table_schema = $1 AND table_type = 'BASE TABLE'
		  ORDER BY table_name`, schema)
	if err != nil {
		return nil, fmt.Errorf("branching: enumerate schema tables: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
