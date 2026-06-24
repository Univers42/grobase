/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   restore_pg.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:06 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"context"
	"fmt"
	"io"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

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
func restoreSchema(ctx context.Context, db *pg.Postgres, schema string, r io.Reader) error {
	body, m, err := splitArtifact(r)
	if err != nil {
		return err
	}
	pconn, err := db.AcquireConn(ctx)
	if err != nil {
		return fmt.Errorf("backup: acquire conn: %w", err)
	}
	defer pconn.Release()

	qschema := pgx.Identifier{schema}.Sanitize()
	qualify := func(tbl string) string { return qschema + "." + pgx.Identifier{tbl}.Sanitize() }
	return restoreTx(ctx, pconn.Conn(), body, m, qualify)
}

// truncateTables TRUNCATEs every backed-up table (in manifest order) inside tx,
// so the deferred rollback can undo them together with the COPYs on any failure.
func truncateTables(ctx context.Context, tx pgx.Tx, m manifest, qualify func(string) string) error {
	for _, te := range m.Tables {
		target := qualify(te.Table)
		if _, err := tx.Exec(ctx, fmt.Sprintf(`TRUNCATE TABLE %s`, target)); err != nil {
			return fmt.Errorf("backup: truncate %s: %w", target, err)
		}
	}
	return nil
}

// restoreTx runs the atomic TRUNCATE+COPY restore for one connection: begin tx,
// truncate each backed-up table, replay the COPY bodies, commit. Any error rolls
// the whole tx back (deferred), so a mid-stream failure leaves the scope reset,
// never partial.
func restoreTx(ctx context.Context, conn *pgx.Conn, body []byte, m manifest, qualify func(string) string) error {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("backup: begin restore tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if err := truncateTables(ctx, tx, m, qualify); err != nil {
		return err
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
// any error. Manifest names are already schema-qualified + pgx.Identifier-sanitized
// at extract time, so the qualify step is identity.
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

	qualify := func(tbl string) string { return tbl }
	return restoreTx(ctx, conn, body, m, qualify)
}
