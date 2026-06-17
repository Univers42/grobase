package export

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
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
func writeBundle(ctx context.Context, conn *pgxpool.Conn, w io.Writer, m Manifest, tbls []exportTable) (Manifest, error) {
	// We must emit the manifest FIRST (so a streaming reader sees it up front) but
	// its row counts are only known after each table is read. Resolve this by
	// counting rows per table first (cheap COUNT(*)), then streaming the data —
	// the manifest is complete before a single data byte is written.
	for i := range tbls {
		n, err := countRows(ctx, conn, tbls[i])
		if err != nil {
			return Manifest{}, err
		}
		m.Tables = append(m.Tables, TableExport{Table: tbls[i].label, Rows: n})
		m.RowCount += n
	}
	m.TableCount = len(m.Tables)

	enc := json.NewEncoder(w)
	// Open the document and write the manifest.
	if _, err := io.WriteString(w, `{"manifest":`); err != nil {
		return Manifest{}, fmt.Errorf("export: write manifest open: %w", err)
	}
	if err := enc.Encode(m); err != nil { // Encode appends a newline — harmless in JSON whitespace
		return Manifest{}, fmt.Errorf("export: encode manifest: %w", err)
	}
	if _, err := io.WriteString(w, `,"data":{`); err != nil {
		return Manifest{}, fmt.Errorf("export: write data open: %w", err)
	}
	for i := range tbls {
		if i > 0 {
			if _, err := io.WriteString(w, ","); err != nil {
				return Manifest{}, err
			}
		}
		// Key: the manifest label (schema-relative for schema_per_tenant, the bare
		// table name for shared_rls), JSON-quoted.
		keyB, _ := json.Marshal(tbls[i].label)
		if _, err := w.Write(keyB); err != nil {
			return Manifest{}, err
		}
		if _, err := io.WriteString(w, ":"); err != nil {
			return Manifest{}, err
		}
		if err := streamTableRows(ctx, conn, w, tbls[i]); err != nil {
			return Manifest{}, err
		}
	}
	if _, err := io.WriteString(w, "}}"); err != nil {
		return Manifest{}, fmt.Errorf("export: write doc close: %w", err)
	}
	return m, nil
}

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
		return fmt.Errorf("export: select %s: %w", t.qualified, err)
	}
	defer rows.Close()

	if _, err := io.WriteString(w, "["); err != nil {
		return err
	}
	first := true
	for rows.Next() {
		vals, verr := rows.Values()
		if verr != nil {
			return fmt.Errorf("export: read row %s: %w", t.qualified, verr)
		}
		rec := make(map[string]any, len(vals))
		for i, fd := range rows.FieldDescriptions() {
			rec[string(fd.Name)] = vals[i]
		}
		b, merr := json.Marshal(rec)
		if merr != nil {
			return fmt.Errorf("export: marshal row %s: %w", t.qualified, merr)
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
	if err := rows.Err(); err != nil {
		return fmt.Errorf("export: iterate %s: %w", t.qualified, err)
	}
	if _, err := io.WriteString(w, "]"); err != nil {
		return err
	}
	return nil
}

// enumerateSchemaTables lists the BASE TABLEs in the tenant's own schema as
// exportTable entries (no filter — the whole table). schema is a bind parameter
// in the catalog query; each identifier is sanitized via pgx.Identifier. Mirrors
// backup.enumerateTables + erase.countSchemaRows table discovery.
func enumerateSchemaTables(ctx context.Context, conn *pgxpool.Conn, schema string) ([]exportTable, error) {
	rows, err := conn.Query(ctx,
		`SELECT table_name FROM information_schema.tables
		  WHERE table_schema = $1 AND table_type = 'BASE TABLE'
		  ORDER BY table_name`, schema)
	if err != nil {
		return nil, fmt.Errorf("export: enumerate schema tables: %w", err)
	}
	defer rows.Close()
	var out []exportTable
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, exportTable{
			qualified: pgx.Identifier{schema, t}.Sanitize(),
			label:     t,
		})
	}
	return out, rows.Err()
}

// enumerateSharedTables lists the shared data tables (every public table carrying
// a tenant_id column, minus the control-plane bookkeeping set the erase service
// excludes) as exportTable entries, EACH carrying the tenant_id filter so the
// SELECT is scoped to ONE tenant. This is the EXACT discovery + exclusion set
// erase.deleteSharedRows uses, but SELECT-scoped instead of DELETE-scoped — so an
// export and an erase see the identical "what is this tenant's shared data" view.
func enumerateSharedTables(ctx context.Context, conn *pgxpool.Conn, tenantID string) ([]exportTable, error) {
	rows, err := conn.Query(ctx, `
		SELECT c.table_name
		  FROM information_schema.columns c
		 WHERE c.table_schema = 'public'
		   AND c.column_name = 'tenant_id'
		   AND c.table_name NOT IN (
		         'tenants','tenant_api_keys','tenant_databases','tenant_usage',
		         'tenant_billing','tenant_backups','tenant_audit_log',
		         'tenant_exports','erasure_receipts','schema_migrations')
		 ORDER BY c.table_name`)
	if err != nil {
		return nil, fmt.Errorf("export: enumerate shared tables: %w", err)
	}
	defer rows.Close()
	var out []exportTable
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, exportTable{
			qualified: pgx.Identifier{"public", t}.Sanitize(),
			label:     t,
			filter:    tenantID,
		})
	}
	return out, rows.Err()
}

// extractScoped acquires a connection, enumerates the tenant's tables per the
// isolation model, and writes the portable bundle to w. The connection is held
// only for the duration of the write (streamed). schema is the resolved
// per-tenant schema (schema_per_tenant) or "" (shared_rls).
func extractScoped(ctx context.Context, db *shared.Postgres, iso, tenantID, schema string, w io.Writer) (Manifest, error) {
	conn, err := db.AcquireConn(ctx)
	if err != nil {
		return Manifest{}, fmt.Errorf("export: acquire conn: %w", err)
	}
	defer conn.Release()

	var tbls []exportTable
	switch iso {
	case "schema_per_tenant":
		if schema == "" {
			return Manifest{}, fmt.Errorf("export: tenant id sanitizes to an empty schema")
		}
		tbls, err = enumerateSchemaTables(ctx, conn, schema)
	case "shared_rls":
		tbls, err = enumerateSharedTables(ctx, conn, tenantID)
	default:
		return Manifest{}, ErrIsolationDeferred
	}
	if err != nil {
		return Manifest{}, err
	}

	m := Manifest{
		TenantID:  tenantID,
		Isolation: iso,
		Engine:    "postgresql",
		Format:    "json",
	}
	return writeBundle(ctx, conn, w, m, tbls)
}
