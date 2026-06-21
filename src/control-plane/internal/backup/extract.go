/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   extract.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:53 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:54 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// manifestSentinel separates the COPY-stream body from the trailing JSON
// manifest footer in an artifact. It is a byte sequence that cannot appear in a
// COPY TEXT stream (COPY TEXT never emits a NUL byte), so the restore reader can
// split body from footer unambiguously.
const manifestSentinel = "\n\x00\x00MANIFEST\x00\x00\n"

// tableExtract is one table's slice in an artifact: its name (for restore
// targeting) and the byte length of its COPY TEXT body (so restore can re-split
// the concatenated stream), plus the row count for completeness validation.
type tableExtract struct {
	Table string `json:"table"`
	Bytes int64  `json:"bytes"`
	Rows  int64  `json:"rows"`
}

// manifest is the JSON footer: the schema/db that was dumped, the per-table
// slices in order, and the engine. Restore reads it to know what to replay.
type manifest struct {
	Schema string         `json:"schema,omitempty"`
	Tables []tableExtract `json:"tables"`
	Engine string         `json:"engine"`
}

// enumerateTables lists the BASE TABLEs in a schema, deterministically ordered.
// schema is a bind parameter — never interpolated.
func enumerateTables(ctx context.Context, conn *pgxpool.Conn, schema string) ([]string, error) {
	rows, err := conn.Query(ctx,
		`SELECT table_name FROM information_schema.tables
		  WHERE table_schema = $1 AND table_type = 'BASE TABLE'
		  ORDER BY table_name`, schema)
	if err != nil {
		return nil, fmt.Errorf("backup: enumerate tables: %w", err)
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

// countingWriter wraps an io.Writer and tallies the bytes written, so we can
// record per-table slice lengths without buffering.
type countingWriter struct {
	w io.Writer
	n int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

// extractSchema streams every BASE TABLE in `schema` as COPY ... TO STDOUT into
// w (concatenated), then writes the manifest sentinel + JSON footer. Identifiers
// are quoted via pgx.Identifier.Sanitize() (double-belt: schema is already
// injection-safe via tenants.TenantSchema, table names come only from
// information_schema). COPY streams straight into w — no full-artifact buffer.
func extractSchema(ctx context.Context, db *pg.Postgres, schema string, w io.Writer) error {
	conn, err := db.AcquireConn(ctx)
	if err != nil {
		return fmt.Errorf("backup: acquire conn: %w", err)
	}
	defer conn.Release()

	tables, err := enumerateTables(ctx, conn, schema)
	if err != nil {
		return err
	}
	m := manifest{Schema: schema, Engine: "postgresql"}
	for _, tbl := range tables {
		cw := &countingWriter{w: w}
		qualified := pgx.Identifier{schema, tbl}.Sanitize()
		tag, err := conn.Conn().PgConn().CopyTo(ctx, cw,
			fmt.Sprintf(`COPY (SELECT * FROM %s) TO STDOUT (FORMAT text)`, qualified))
		if err != nil {
			return fmt.Errorf("backup: COPY TO %s: %w", qualified, err)
		}
		m.Tables = append(m.Tables, tableExtract{Table: tbl, Bytes: cw.n, Rows: tag.RowsAffected()})
	}
	return writeManifest(w, m)
}

// extractDatabase dials a tenant's OWN database via its resolved DSN, enumerates
// the public (+ tenant) schemas, and COPYs every table. Used for db_per_tenant
// where the tenant has a dedicated database. NEVER touches the shared
// control-plane DB.
func extractDatabase(ctx context.Context, dsn string, w io.Writer) error {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return fmt.Errorf("backup: dial tenant db: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()

	schemas, err := enumerateDBSchemas(ctx, conn)
	if err != nil {
		return err
	}
	m := manifest{Engine: "postgresql"}
	for _, sc := range schemas {
		if err := copyDBSchema(ctx, conn, sc, w, &m); err != nil {
			return err
		}
	}
	return writeManifest(w, m)
}

// writeManifest appends the sentinel + JSON footer to the artifact stream.
func writeManifest(w io.Writer, m manifest) error {
	if _, err := io.WriteString(w, manifestSentinel); err != nil {
		return fmt.Errorf("backup: write manifest sentinel: %w", err)
	}
	enc, err := json.Marshal(m)
	if err != nil {
		return fmt.Errorf("backup: marshal manifest: %w", err)
	}
	if _, err := w.Write(enc); err != nil {
		return fmt.Errorf("backup: write manifest: %w", err)
	}
	return nil
}
