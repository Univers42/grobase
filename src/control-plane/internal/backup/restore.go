/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   restore.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:08 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:10 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/jackc/pgx/v5"
)

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
