/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:08 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:09 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package compliance

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// sdb is the minimal Postgres surface the Service needs. *pg.Postgres
// satisfies it (the collector + read API run as the BYPASSRLS control-plane
// service role); a fake satisfies it in unit tests so the persist + read
// contracts are provable without a live database.
type sdb interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// complianceErr is the package's const-error type: a sentinel is a typed string
// constant, so errors.Is / %w wrapping still work (equal value+type == equal
// error) with no package-level var. Error() returns the message verbatim.
// errNoSnapshot is returned by the read API when a requested snapshot has no
// rows (so the handler maps it to 404 rather than an empty 200).
const errNoSnapshot complianceErr = "compliance: snapshot not found"

// Service persists collector snapshots into public.compliance_evidence (each row
// sealed) and reads them back for the verify / read API. It is the durable twin
// of the audit service: one sealing writer + scoped readers.
type Service struct {
	db        sdb
	collector *Collector
}

// NewService wraps the privileged Postgres handle and builds the collector from
// env. db must satisfy BOTH sdb (for persist/read) and the collector's accessDB
// (for the access-review section); *pg.Postgres satisfies both via the
// rowsAdapter wrapping in collectAccess below.
func NewService(db sdb) *Service {
	return &Service{db: db, collector: NewCollector(accessAdapter{db})}
}

// accessAdapter bridges sdb (pgx.Rows) to the collector's accessDB (pgxRows).
// pgx.Rows structurally satisfies pgxRows, but Go does not implicitly convert a
// method's concrete return type to a different interface type, so this thin
// adapter performs the (interface-to-interface) handoff explicitly.
type accessAdapter struct{ db sdb }

// AdminQuery forwards to the wrapped sdb and returns its pgx.Rows as a pgxRows;
// pgx.Rows satisfies pgxRows structurally, so the returned rows need no
// conversion beyond this interface-to-interface handoff.
func (a accessAdapter) AdminQuery(ctx context.Context, sql string, args ...any) (pgxRows, error) {
	rows, err := a.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return rows, nil
}

// Collect runs the collector, then SEALS and PERSISTS each of the three section
// rows under one snapshot_id. Each row's hash = SealHash(section, collected_at,
// payload) — the SAME seal Verify recomputes, so a freshly collected snapshot
// always verifies intact. Returns the snapshot id + the sealed rows.
func (s *Service) Collect(ctx context.Context) (string, []EvidenceRow, error) {
	snap, err := s.collector.Collect(ctx)
	if err != nil {
		return "", nil, err
	}
	snapshotID, err := newUUID()
	if err != nil {
		return "", nil, err
	}
	out := make([]EvidenceRow, 0, len(snap.Sections))
	for _, sp := range snap.Sections {
		row, err := s.sealRow(ctx, snapshotID, snap.CollectedAt, sp)
		if err != nil {
			return "", nil, err
		}
		out = append(out, row)
	}
	return snapshotID, out, nil
}

// sealRow seals one section payload (hash = SealHash(section, collected_at,
// payload)) and persists it, returning the sealed EvidenceRow with its assigned
// id.
func (s *Service) sealRow(ctx context.Context, snapshotID string, at time.Time, sp SectionPayload) (EvidenceRow, error) {
	payload := normalizePayload(sp.Payload)
	hash := SealHash(sp.Section, at, payload)
	var id string
	if err := s.insert(ctx, insertParams{
		snapshotID: snapshotID, at: at, section: sp.Section,
		payload: payload, hash: hash, idOut: &id,
	}); err != nil {
		return EvidenceRow{}, err
	}
	return EvidenceRow{
		ID:          id,
		SnapshotID:  snapshotID,
		CollectedAt: at,
		Section:     sp.Section,
		Payload:     payload,
		Hash:        hash,
	}, nil
}

// insertParams groups the evidence-row insert inputs for insert (formerly its
// positional args, 1:1).
type insertParams struct {
	snapshotID string
	at         time.Time
	section    string
	payload    []byte
	hash       string
	idOut      *string
}

// insert writes one sealed evidence row and returns its assigned id. Kept as a
// QueryRow (via AdminQuery) so RETURNING id round-trips without a second read.
func (s *Service) insert(ctx context.Context, p insertParams) error {
	rows, err := s.db.AdminQuery(ctx, `
		INSERT INTO public.compliance_evidence
		  (snapshot_id, collected_at, section, payload, hash)
		VALUES ($1,$2,$3,$4,$5)
		RETURNING id`,
		p.snapshotID, p.at, p.section, p.payload, p.hash)
	if err != nil {
		return err
	}
	defer rows.Close()
	if rows.Next() {
		if err := rows.Scan(p.idOut); err != nil {
			return err
		}
	}
	return rows.Err()
}
