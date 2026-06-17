package branching

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrInvalidBranchName is returned when a caller-supplied branch name does not
// sanitize to a non-empty safe identifier. The handler maps it to 400. This is
// the LOAD-BEARING wall against SQL-identifier injection: the branch name flows
// into `CREATE SCHEMA <branch_schema>` (an identifier, never bindable), so it MUST
// be validated to a safe [a-z0-9_] fragment before it touches DDL.
var ErrInvalidBranchName = errors.New("invalid branch name (must be a non-empty [a-z0-9_] identifier)")

// sanitizeBranchName validates+normalizes a caller-supplied branch name to a safe
// SQL identifier fragment, mirroring tenants.tenantSchema's discipline (lowercase,
// keep [a-z0-9_], everything else is NOT silently rewritten — a name with an
// out-of-class char is REJECTED so a caller cannot smuggle `x; DROP SCHEMA …`
// past us). We reject (not rewrite) because a branch name is caller-facing and
// silently mangling it would make the branch un-findable by its name; rejecting
// is the honest, safe contract. Returns the normalized (lowercased) fragment.
//
// THIS IS THE SQL-IDENTIFIER-INJECTION GUARD. The returned value is interpolated
// into branchSchema(), which is interpolated into CREATE SCHEMA DDL (identifiers
// cannot be bind params). branching_test.go pins this against meta-char inputs.
func sanitizeBranchName(name string) (string, error) {
	name = strings.TrimSpace(strings.ToLower(name))
	if name == "" {
		return "", ErrInvalidBranchName
	}
	if len(name) > 40 {
		return "", ErrInvalidBranchName
	}
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
			// ok
		default:
			// Any meta char (';', ' ', '"', '-', etc.) is a hard reject — this is
			// the injection wall, not a best-effort cleanup.
			return "", ErrInvalidBranchName
		}
	}
	// A branch name that is ALL underscores trims to empty -> not a usable schema
	// suffix; reject it too.
	if strings.Trim(name, "_") == "" {
		return "", ErrInvalidBranchName
	}
	return name, nil
}

// branchSchema derives the Postgres schema name a branch's clone lives in. Both
// inputs are pre-sanitized — parentSchema by tenants.TenantSchema (already
// `tenant_<frag>`), branchName by sanitizeBranchName ([a-z0-9_]) — so the result
// is a safe identifier. Shape: <parentSchema>_br_<branchName>, truncated so the
// whole thing stays inside Postgres's 63-byte identifier limit.
func branchSchema(parentSchema, branchName string) string {
	const sep = "_br_"
	s := parentSchema + sep + branchName
	if len(s) > 63 {
		s = s[:63]
	}
	return s
}

// cloneSchema clones every BASE TABLE in parentSchema into branchSchema (a fresh
// schema), copying ALL rows, over the existing pgx pool — NO pg_dump. It returns
// the number of tables cloned and the total rows copied. Both schema names are
// already-sanitized identifiers (tenants.TenantSchema + sanitizeBranchName), and
// each is additionally quoted via pgx.Identifier.Sanitize() (double-belt). The
// clone runs in ONE transaction so a mid-clone failure leaves NO half-built
// schema (all-or-nothing).
func cloneSchema(ctx context.Context, db *shared.Postgres, parentSchema, branchSchemaName string) (int, int64, error) {
	conn, err := db.AcquireConn(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("branching: acquire conn: %w", err)
	}
	defer conn.Release()

	tables, err := enumerateSchemaTables(ctx, conn, parentSchema)
	if err != nil {
		return 0, 0, err
	}

	tx, err := conn.Begin(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("branching: begin clone tx: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	branchQ := pgx.Identifier{branchSchemaName}.Sanitize()
	if _, err := tx.Exec(ctx, fmt.Sprintf(`CREATE SCHEMA %s`, branchQ)); err != nil {
		return 0, 0, fmt.Errorf("branching: create branch schema %s: %w", branchSchemaName, err)
	}

	var total int64
	for _, t := range tables {
		parentT := pgx.Identifier{parentSchema, t}.Sanitize()
		branchT := pgx.Identifier{branchSchemaName, t}.Sanitize()
		// Structure: INCLUDING ALL copies columns, defaults, constraints, indexes.
		if _, err := tx.Exec(ctx,
			fmt.Sprintf(`CREATE TABLE %s (LIKE %s INCLUDING ALL)`, branchT, parentT)); err != nil {
			return 0, 0, fmt.Errorf("branching: create table %s: %w", branchT, err)
		}
		// Data: full row copy.
		tag, err := tx.Exec(ctx, fmt.Sprintf(`INSERT INTO %s SELECT * FROM %s`, branchT, parentT))
		if err != nil {
			return 0, 0, fmt.Errorf("branching: copy rows %s: %w", branchT, err)
		}
		total += tag.RowsAffected()
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, 0, fmt.Errorf("branching: commit clone tx: %w", err)
	}
	committed = true
	return len(tables), total, nil
}

// dropSchema removes a branch's schema and everything in it (CASCADE), over the
// pool. branchSchemaName is the already-sanitized schema recorded in the ledger;
// it is re-quoted via pgx.Identifier (double-belt). `IF EXISTS` makes a re-drop a
// no-op, so dropping an already-gone branch is idempotent.
func dropSchema(ctx context.Context, db *shared.Postgres, branchSchemaName string) error {
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

// resolveParentSchema resolves the per-tenant schema a branch forks from, reusing
// the SINGLE-SOURCE sanitizer tenants.TenantSchema (the same schema name a mount
// was provisioned under). Returns ErrNoMount when the id sanitizes to empty.
func resolveParentSchema(tenantID string) (string, error) {
	schema := tenants.TenantSchema(tenantID)
	if schema == "" {
		return "", fmt.Errorf("branching: tenant id sanitizes to an empty schema")
	}
	return schema, nil
}
