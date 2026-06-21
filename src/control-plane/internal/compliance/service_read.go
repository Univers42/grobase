/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_read.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:04 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:06 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package compliance

import (
	"context"
	"encoding/json"
)

const listLatestSQL = `
SELECT id, snapshot_id, collected_at, section, payload, hash
  FROM public.compliance_evidence
 WHERE snapshot_id = (
   SELECT snapshot_id FROM public.compliance_evidence
    ORDER BY collected_at DESC, snapshot_id LIMIT 1)
 ORDER BY section`

const listBySnapshotSQL = `
SELECT id, snapshot_id, collected_at, section, payload, hash
  FROM public.compliance_evidence
 WHERE snapshot_id = $1
 ORDER BY section`

// Latest returns the most recent snapshot's sealed rows (all three sections).
func (s *Service) Latest(ctx context.Context) (string, []EvidenceRow, error) {
	return s.scan(ctx, listLatestSQL)
}

// BySnapshot returns one snapshot's sealed rows.
func (s *Service) BySnapshot(ctx context.Context, snapshotID string) (string, []EvidenceRow, error) {
	return s.scan(ctx, listBySnapshotSQL, snapshotID)
}

func (s *Service) scan(ctx context.Context, sql string, args ...any) (string, []EvidenceRow, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return "", nil, err
	}
	defer rows.Close()
	out := make([]EvidenceRow, 0, 3)
	var snapshotID string
	for rows.Next() {
		var e EvidenceRow
		var payload []byte
		if err := rows.Scan(&e.ID, &e.SnapshotID, &e.CollectedAt, &e.Section, &payload, &e.Hash); err != nil {
			return "", nil, err
		}
		e.Payload = normalizePayload(payload)
		snapshotID = e.SnapshotID
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return "", nil, err
	}
	if len(out) == 0 {
		return "", nil, errNoSnapshot
	}
	return snapshotID, out, nil
}

// Verify reads a snapshot (latest when snapshotID is empty) and recomputes every
// row's seal via VerifySnapshot. Because scan binds snapshot_id and the rows are
// the platform-level evidence, the slice handed to the pure verifier is exactly
// that snapshot — a tampered row is detected at exactly its section.
func (s *Service) Verify(ctx context.Context, snapshotID string) (VerifyResult, error) {
	var (
		sid  string
		rows []EvidenceRow
		err  error
	)
	if snapshotID == "" {
		sid, rows, err = s.Latest(ctx)
	} else {
		sid, rows, err = s.BySnapshot(ctx, snapshotID)
	}
	if err != nil {
		return VerifyResult{}, err
	}
	return VerifySnapshot(sid, rows), nil
}

// normalizePayload guarantees a non-nil, valid JSON payload ('{}' default),
// mirroring the table's DEFAULT '{}'::jsonb — so the seal never hashes a NULL.
func normalizePayload(p []byte) json.RawMessage {
	if len(p) == 0 {
		return json.RawMessage(`{}`)
	}
	return json.RawMessage(p)
}
