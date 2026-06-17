package export

import (
	"context"
	"fmt"
	"io"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

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
	return scanExportTables(rows, func(t string) exportTable {
		return exportTable{qualified: pgx.Identifier{schema, t}.Sanitize(), label: t}
	})
}

// scanExportTables drains a single-column table_name result, mapping each name
// to an exportTable via build, and closes the rows.
func scanExportTables(rows pgx.Rows, build func(string) exportTable) ([]exportTable, error) {
	defer rows.Close()
	var out []exportTable
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, build(t))
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
	return scanExportTables(rows, func(t string) exportTable {
		return exportTable{qualified: pgx.Identifier{"public", t}.Sanitize(), label: t, filter: tenantID}
	})
}

// extractScoped acquires a connection, enumerates the tenant's tables per the
// isolation model, and writes the portable bundle to w. The connection is held
// only for the duration of the write (streamed). schema is the resolved
// per-tenant schema (schema_per_tenant) or "" (shared_rls).
func extractScoped(ctx context.Context, db *pg.Postgres, iso, tenantID, schema string, w io.Writer) (Manifest, error) {
	conn, err := db.AcquireConn(ctx)
	if err != nil {
		return Manifest{}, fmt.Errorf("export: acquire conn: %w", err)
	}
	defer conn.Release()

	tbls, err := enumerateForIsolation(ctx, conn, iso, tenantID, schema)
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

// enumerateForIsolation lists the tenant's exportable tables per the isolation
// model (schema_per_tenant -> own schema, shared_rls -> tenant_id-filtered
// shared tables), rejecting the deferred models.
func enumerateForIsolation(ctx context.Context, conn *pgxpool.Conn, iso, tenantID, schema string) ([]exportTable, error) {
	switch iso {
	case "schema_per_tenant":
		if schema == "" {
			return nil, fmt.Errorf("export: tenant id sanitizes to an empty schema")
		}
		return enumerateSchemaTables(ctx, conn, schema)
	case "shared_rls":
		return enumerateSharedTables(ctx, conn, tenantID)
	default:
		return nil, ErrIsolationDeferred
	}
}
