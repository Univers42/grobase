/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   extract.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:25 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:26 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package export

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TableExport is one table's slice in the portable manifest: its name and the
// number of rows exported for THIS tenant. (For shared_rls the count is the
// WHERE tenant_id-filtered count, never the whole shared table.)
type TableExport struct {
	Table string `json:"table"`
	Rows  int64  `json:"rows"`
}

// Manifest is the portable, self-describing header of a bundle: the tenant it
// belongs to, the isolation model it was scoped under, the engine, the per-table
// row counts, and the total. The bundle's sha256 (integrity proof) is recorded
// in the ledger row, not inside the manifest (it hashes the whole bundle, of
// which the manifest is a part). A downstream consumer reads `Tables` to know
// exactly which tables + how many rows it received.
type Manifest struct {
	TenantID   string        `json:"tenant_id"`
	Isolation  string        `json:"isolation"`
	Engine     string        `json:"engine"`
	Format     string        `json:"format"`
	Tables     []TableExport `json:"tables"`
	TableCount int           `json:"table_count"`
	RowCount   int64         `json:"row_count"`
}

// writeBundle streams a single self-describing JSON document to w:
//
//	{"manifest": {...}, "data": {"<table>": [ {row}, {row}, … ], …}}
//
// The document is genuinely PORTABLE — one JSON file a tenant can open anywhere,
// no COPY-format opacity. Rows are streamed table-by-table so a large export
// never buffers the whole dataset in memory (only one row's column map at a
// time). enumerate yields the (qualified-for-query, label-for-manifest) table
// pairs + the optional tenant_id filter; the caller (schema vs shared) supplies
// the right enumeration so this writer is isolation-agnostic.
//
// It returns the computed Manifest (table list + counts) so the service can
// record it in the ledger. The bundle's sha256/size come from the store's Upload
// (it tees the stream), so this function only PRODUCES the bytes.
//
// The manifest must be emitted FIRST (so a streaming reader sees it up front) but
// its row counts are only known after each table is read; resolved by counting
// rows per table first (cheap COUNT(*)), then streaming the data — so the
// manifest is complete before a single data byte is written.
func writeBundle(ctx context.Context, conn *pgxpool.Conn, w io.Writer, m Manifest, tbls []exportTable) (Manifest, error) {
	m, err := countManifestRows(ctx, conn, m, tbls)
	if err != nil {
		return Manifest{}, err
	}
	if err := writeManifestHeader(w, m); err != nil {
		return Manifest{}, err
	}
	if err := writeBundleData(ctx, conn, w, tbls); err != nil {
		return Manifest{}, err
	}
	if _, err := io.WriteString(w, "}}"); err != nil {
		return Manifest{}, fmt.Errorf("export: write doc close: %w", err)
	}
	return m, nil
}

// countManifestRows fills the manifest's per-table counts + total with cheap
// COUNT(*)s before any data byte is streamed.
func countManifestRows(ctx context.Context, conn *pgxpool.Conn, m Manifest, tbls []exportTable) (Manifest, error) {
	for i := range tbls {
		n, err := countRows(ctx, conn, tbls[i])
		if err != nil {
			return Manifest{}, err
		}
		m.Tables = append(m.Tables, TableExport{Table: tbls[i].label, Rows: n})
		m.RowCount += n
	}
	m.TableCount = len(m.Tables)
	return m, nil
}

// writeManifestHeader opens the document and emits the complete manifest plus
// the `"data":{` opener. json.Encode appends a newline, harmless in JSON
// whitespace.
func writeManifestHeader(w io.Writer, m Manifest) error {
	if _, err := io.WriteString(w, `{"manifest":`); err != nil {
		return fmt.Errorf("export: write manifest open: %w", err)
	}
	if err := json.NewEncoder(w).Encode(m); err != nil {
		return fmt.Errorf("export: encode manifest: %w", err)
	}
	if _, err := io.WriteString(w, `,"data":{`); err != nil {
		return fmt.Errorf("export: write data open: %w", err)
	}
	return nil
}

// writeBundleData streams each table as `"<label>": [rows]`, comma-separated.
// The key is the manifest label (schema-relative for schema_per_tenant, the bare
// table name for shared_rls), JSON-quoted.
func writeBundleData(ctx context.Context, conn *pgxpool.Conn, w io.Writer, tbls []exportTable) error {
	for i := range tbls {
		if i > 0 {
			if _, err := io.WriteString(w, ","); err != nil {
				return err
			}
		}
		keyB, _ := json.Marshal(tbls[i].label)
		if _, err := w.Write(keyB); err != nil {
			return err
		}
		if _, err := io.WriteString(w, ":"); err != nil {
			return err
		}
		if err := streamTableRows(ctx, conn, w, tbls[i]); err != nil {
			return err
		}
	}
	return nil
}
