/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rows.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:39 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:40 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package export

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// exportTable is one table to export: the sanitized, schema-qualified identifier
// used in the SELECT, the label recorded in the manifest, and (shared_rls only)
// the tenant_id bind value used to scope the SELECT. filter=="" means no filter
// (schema_per_tenant — the whole table in the tenant's own schema).
type exportTable struct {
	qualified string // pgx.Identifier-sanitized, e.g. "tenant_x"."notes" or "public"."notes"
	label     string // manifest key, e.g. "notes"
	filter    string // shared_rls tenant_id bind value; "" => no WHERE
}

// countRows returns the row count this tenant will receive for one table —
// COUNT(*) for schema_per_tenant, COUNT(*) WHERE tenant_id=$1 for shared_rls.
func countRows(ctx context.Context, conn *pgxpool.Conn, t exportTable) (int64, error) {
	var n int64
	if t.filter == "" {
		err := conn.QueryRow(ctx, fmt.Sprintf(`SELECT count(*) FROM %s`, t.qualified)).Scan(&n)
		if err != nil {
			return 0, fmt.Errorf("export: count %s: %w", t.qualified, err)
		}
		return n, nil
	}
	err := conn.QueryRow(ctx,
		fmt.Sprintf(`SELECT count(*) FROM %s WHERE tenant_id = $1`, t.qualified), t.filter).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("export: count %s (scoped): %w", t.qualified, err)
	}
	return n, nil
}

// streamTableRows writes one table's rows as a JSON array [ {col:val,…}, … ] to
// w, one row at a time (no full-table buffer). Each row is a column->value map
// built from pgx's RowToMap, so the output is portable JSON regardless of column
// types. For shared_rls the SELECT is scoped WHERE tenant_id = $1 (the bind), so
// only THIS tenant's rows are ever read — a cross-tenant leak is impossible by
// construction (the same wall D4.4 erase's deleteSharedRows uses).
func streamTableRows(ctx context.Context, conn *pgxpool.Conn, w io.Writer, t exportTable) error {
	rows, err := queryTableRows(ctx, conn, t)
	if err != nil {
		return err
	}
	defer rows.Close()
	if _, err := io.WriteString(w, "["); err != nil {
		return err
	}
	if err := encodeRowArray(w, rows, t.qualified); err != nil {
		return err
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("export: iterate %s: %w", t.qualified, err)
	}
	if _, err := io.WriteString(w, "]"); err != nil {
		return err
	}
	return nil
}

// queryTableRows opens the SELECT for one table — scoped WHERE tenant_id = $1
// for shared_rls (filter != ""), the whole table otherwise.
func queryTableRows(ctx context.Context, conn *pgxpool.Conn, t exportTable) (pgx.Rows, error) {
	var (
		rows pgx.Rows
		err  error
	)
	if t.filter == "" {
		rows, err = conn.Query(ctx, fmt.Sprintf(`SELECT * FROM %s`, t.qualified))
	} else {
		rows, err = conn.Query(ctx,
			fmt.Sprintf(`SELECT * FROM %s WHERE tenant_id = $1`, t.qualified), t.filter)
	}
	if err != nil {
		return nil, fmt.Errorf("export: select %s: %w", t.qualified, err)
	}
	return rows, nil
}

// encodeRowArray writes each row as a comma-separated column->value JSON object
// into the already-opened `[` array (one row's column map buffered at a time).
func encodeRowArray(w io.Writer, rows pgx.Rows, qualified string) error {
	first := true
	for rows.Next() {
		b, merr := marshalRow(rows, qualified)
		if merr != nil {
			return merr
		}
		if !first {
			if _, err := io.WriteString(w, ","); err != nil {
				return err
			}
		}
		first = false
		if _, err := w.Write(b); err != nil {
			return err
		}
	}
	return nil
}

// marshalRow builds the current row's column->value map and marshals it to JSON.
func marshalRow(rows pgx.Rows, qualified string) ([]byte, error) {
	vals, verr := rows.Values()
	if verr != nil {
		return nil, fmt.Errorf("export: read row %s: %w", qualified, verr)
	}
	rec := make(map[string]any, len(vals))
	for i, fd := range rows.FieldDescriptions() {
		rec[string(fd.Name)] = vals[i]
	}
	b, merr := json.Marshal(rec)
	if merr != nil {
		return nil, fmt.Errorf("export: marshal row %s: %w", qualified, merr)
	}
	return b, nil
}
