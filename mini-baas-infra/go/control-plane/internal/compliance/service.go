package compliance

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

// sdb is the minimal Postgres surface the Service needs. *shared.Postgres
// satisfies it (the collector + read API run as the BYPASSRLS control-plane
// service role); a fake satisfies it in unit tests so the persist + read
// contracts are provable without a live database.
type sdb interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// errNoSnapshot is returned by the read API when a requested snapshot has no
// rows (so the handler maps it to 404 rather than an empty 200).
var errNoSnapshot = errors.New("compliance: snapshot not found")

// Service persists collector snapshots into public.compliance_evidence (each row
// sealed) and reads them back for the verify / read API. It is the durable twin
// of the audit service: one sealing writer + scoped readers.
type Service struct {
	db        sdb
	collector *Collector
}

// NewService wraps the privileged Postgres handle and builds the collector from
// env. db must satisfy BOTH sdb (for persist/read) and the collector's accessDB
// (for the access-review section); *shared.Postgres satisfies both via the
// rowsAdapter wrapping in collectAccess below.
func NewService(db sdb) *Service {
	return &Service{db: db, collector: NewCollector(accessAdapter{db})}
}

// accessAdapter bridges sdb (pgx.Rows) to the collector's accessDB (pgxRows).
// pgx.Rows structurally satisfies pgxRows, but Go does not implicitly convert a
// method's concrete return type to a different interface type, so this thin
// adapter performs the (interface-to-interface) handoff explicitly.
type accessAdapter struct{ db sdb }

func (a accessAdapter) AdminQuery(ctx context.Context, sql string, args ...any) (pgxRows, error) {
	rows, err := a.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return rows, nil // pgx.Rows satisfies pgxRows structurally
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
		payload := normalizePayload(sp.Payload)
		hash := SealHash(sp.Section, snap.CollectedAt, payload)
		var id string
		if e := s.insert(ctx, snapshotID, snap.CollectedAt, sp.Section, payload, hash, &id); e != nil {
			return "", nil, e
		}
		out = append(out, EvidenceRow{
			ID:          id,
			SnapshotID:  snapshotID,
			CollectedAt: snap.CollectedAt,
			Section:     sp.Section,
			Payload:     payload,
			Hash:        hash,
		})
	}
	return snapshotID, out, nil
}

// StartScheduler OPTIONALLY runs the collector on a fixed interval in a
// background goroutine. It is a no-op (returns immediately, starting nothing)
// unless SOC2_EVIDENCE_SCHEDULE parses to a positive duration — the DEFAULT
// (unset/empty) is TODAY'S behavior: no ticker, snapshots only on explicit POST
// /v1/compliance/collect.
//
// PARITY: the caller (cmd/tenant-control) only invokes this inside the
// SOC2_EVIDENCE_ENABLED branch, so with the flag OFF this method is never even
// called; and even when called, an empty/invalid SOC2_EVIDENCE_SCHEDULE starts
// no goroutine. The ticker stops cleanly when ctx is cancelled (process
// shutdown), so it leaks nothing.
//
// It does NOT take an initial snapshot on start — the first tick fires after one
// interval — keeping start-up byte-identical to the no-schedule path.
func (s *Service) StartScheduler(ctx context.Context) {
	raw := os.Getenv("SOC2_EVIDENCE_SCHEDULE")
	if raw == "" {
		return // default: no scheduled snapshots (today's behavior)
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		slog.Warn("compliance: ignoring invalid SOC2_EVIDENCE_SCHEDULE (want a positive Go duration, e.g. 24h)",
			"value", raw, "err", err)
		return
	}
	slog.Info("compliance: scheduled evidence snapshots enabled", "interval", d.String())
	go func() {
		t := time.NewTicker(d)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				sid, _, cerr := s.Collect(ctx)
				if cerr != nil {
					slog.Error("compliance: scheduled snapshot failed", "err", cerr)
					continue
				}
				slog.Info("compliance: scheduled snapshot sealed", "snapshot_id", sid)
			}
		}
	}()
}

// insert writes one sealed evidence row and returns its assigned id. Kept as a
// QueryRow (via AdminQuery) so RETURNING id round-trips without a second read.
func (s *Service) insert(ctx context.Context, snapshotID string, at time.Time, section string, payload []byte, hash string, idOut *string) error {
	rows, err := s.db.AdminQuery(ctx, `
		INSERT INTO public.compliance_evidence
		  (snapshot_id, collected_at, section, payload, hash)
		VALUES ($1,$2,$3,$4,$5)
		RETURNING id`,
		snapshotID, at, section, payload, hash)
	if err != nil {
		return err
	}
	defer rows.Close()
	if rows.Next() {
		if err := rows.Scan(idOut); err != nil {
			return err
		}
	}
	return rows.Err()
}

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

// newUUID mints a RFC-4122 v4 UUID string from crypto/rand. The control-plane
// module does not vendor github.com/google/uuid (the audit/backup tables use the
// DB-side gen_random_uuid() default); snapshot_id has no DB default, so we mint
// it in Go without adding a dependency. 16 random bytes with the version/variant
// nibbles set is a standard, collision-safe v4.
func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}
