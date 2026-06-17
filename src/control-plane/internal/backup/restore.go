package backup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// ErrIsolationDeferred is returned when a backup/restore is requested for an
// isolation model the B6 MVP does NOT support yet: db_per_tenant (its
// extract/restore code paths exist but the DSN resolver is not wired and the
// round-trip is not gate-proven — deferred to B6b), plus shared_rls (filtered
// dump + upsert into a LIVE shared table) and tenant_owned (external DB). The
// handler maps it to 400. The deferral is also enforced structurally by the
// migration 042 CHECK (schema_per_tenant only), so a deferred row can't exist.
var ErrIsolationDeferred = errors.New("isolation not supported for backup/restore (deferred)")

// guardIsolation rejects anything outside the MVP-clean isolation model. Only
// schema_per_tenant is supported today; db_per_tenant is deferred to B6b (wire
// Service.WithResolver in main.go, re-add it here + to the 042 CHECK, add an m87
// arm). Never advertise support we can't deliver.
func guardIsolation(iso string) error {
	switch iso {
	case "schema_per_tenant":
		return nil
	default:
		return ErrIsolationDeferred
	}
}

// splitArtifact reads the full artifact, splits the concatenated COPY bodies
// from the trailing JSON manifest at the sentinel, and parses the manifest. The
// returned body is re-sliced per table by the manifest's recorded byte lengths.
func splitArtifact(r io.Reader) ([]byte, manifest, error) {
	all, err := io.ReadAll(r)
	if err != nil {
		return nil, manifest{}, fmt.Errorf("backup: read artifact: %w", err)
	}
	idx := bytes.LastIndex(all, []byte(manifestSentinel))
	if idx < 0 {
		return nil, manifest{}, fmt.Errorf("backup: artifact missing manifest footer")
	}
	body := all[:idx]
	footer := all[idx+len(manifestSentinel):]
	var m manifest
	if err := json.Unmarshal(footer, &m); err != nil {
		return nil, manifest{}, fmt.Errorf("backup: parse manifest: %w", err)
	}
	return body, m, nil
}

// replayTables splits body by the manifest's per-table byte lengths and replays
// each table via COPY <table> FROM STDIN (FORMAT text) on the TRANSACTION'S
// connection (tx.Conn()), so every COPY executes INSIDE tx alongside the
// TRUNCATEs: a mid-stream COPY failure aborts the tx and the deferred
// tx.Rollback undoes the TRUNCATEs AND every already-replayed COPY together —
// the restore is all-or-nothing, never a partial/corrupted state. (pgx
// transactions are connection-bound, so a raw-protocol COPY issued on the tx's
// own connection participates in that tx; proven empirically by m87's atomicity
// arm, which forces a second-table COPY failure and asserts the first table
// rolled back.) qualify maps a manifest table name to the fully-qualified,
// sanitized identifier the COPY targets.
func replayTables(ctx context.Context, tx pgx.Tx, body []byte, m manifest, qualify func(string) string) error {
	var off int64
	for _, te := range m.Tables {
		end := off + te.Bytes
		if end > int64(len(body)) {
			return fmt.Errorf("backup: artifact truncated for table %s", te.Table)
		}
		slice := body[off:end]
		off = end
		target := qualify(te.Table)
		if _, err := tx.Conn().PgConn().CopyFrom(ctx, bytes.NewReader(slice),
			fmt.Sprintf(`COPY %s FROM STDIN (FORMAT text)`, target)); err != nil {
			return fmt.Errorf("backup: COPY FROM %s: %w", target, err)
		}
	}
	return nil
}

// restoreSchema restores a schema_per_tenant backup into A's OWN schema only:
// one transaction that TRUNCATEs each backed-up table in <schema> then replays
// COPY ... FROM STDIN. Any error rolls the whole tx back (no partial restore).
// B's schema lives in a DIFFERENT namespace and is untouched by construction.
// `schema` MUST come from tenants.TenantSchema (injection-safe).
//
// Why TRUNCATE+COPY (not DROP SCHEMA CASCADE + CREATE): the data plane
// provisions a tenant's tables (DDL) at mount time, so restore targets the live
// table set and replays DATA back into it — destroying+recreating the schema
// would erase the table DDL (this artifact carries data, not DDL). A full
// DDL-snapshot restore (column/type recreation) is a documented B6b follow-up;
// for the two MVP-clean isolation models the data-replay restore is exact for an
// unchanged table shape, which is the gate's round-trip contract.
func restoreSchema(ctx context.Context, db *shared.Postgres, schema string, r io.Reader) error {
	body, m, err := splitArtifact(r)
	if err != nil {
		return err
	}
	pconn, err := db.AcquireConn(ctx)
	if err != nil {
		return fmt.Errorf("backup: acquire conn: %w", err)
	}
	defer pconn.Release()
	conn := pconn.Conn()

	qschema := pgx.Identifier{schema}.Sanitize()
	qualify := func(tbl string) string { return qschema + "." + pgx.Identifier{tbl}.Sanitize() }

	tx, err := conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("backup: begin restore tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// TRUNCATE every backed-up table in A's schema, then COPY the rows back — all
	// inside one tx so a mid-stream failure leaves A fully reset, never partial.
	for _, te := range m.Tables {
		target := qualify(te.Table)
		if _, err := tx.Exec(ctx, fmt.Sprintf(`TRUNCATE TABLE %s`, target)); err != nil {
			return fmt.Errorf("backup: truncate %s: %w", target, err)
		}
	}
	if err := replayTables(ctx, tx, body, m, qualify); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("backup: commit restore: %w", err)
	}
	return nil
}

// restoreDatabase restores a db_per_tenant backup into A's OWN database via the
// resolved DSN: per-table TRUNCATE + COPY FROM STDIN inside one transaction.
// NEVER the shared control-plane DB; NEVER a shared object. Atomic — rollback on
// any error. Table names in the manifest are already schema-qualified.
func restoreDatabase(ctx context.Context, dsn string, r io.Reader) error {
	body, m, err := splitArtifact(r)
	if err != nil {
		return err
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return fmt.Errorf("backup: dial tenant db: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()

	tx, err := conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("backup: begin restore tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// TRUNCATE then COPY each table (manifest names are schema-qualified, already
	// pgx.Identifier-sanitized at extract time).
	for _, te := range m.Tables {
		if _, err := tx.Exec(ctx, fmt.Sprintf(`TRUNCATE TABLE %s`, te.Table)); err != nil {
			return fmt.Errorf("backup: truncate %s: %w", te.Table, err)
		}
	}
	qualify := func(tbl string) string { return tbl } // already schema-qualified
	if err := replayTables(ctx, tx, body, m, qualify); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
