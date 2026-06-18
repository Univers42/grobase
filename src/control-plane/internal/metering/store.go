// Package metering is the control-plane sink for the flag-gated per-tenant usage
// pipeline (Track-B B1b). The data plane (DATA_PLANE_METERING) and extra planes
// emit windowed (tenant_id, metric, qty, ts) rollups onto the `usage.events`
// Redis stream; this package's consumer (gated behind METERING_INGEST, default
// OFF) reads that stream and idempotently UPSERTs each entry into
// public.tenant_usage. With METERING_INGEST off the consumer never subscribes,
// so the control plane is byte-parity with today.
package metering

import (
	"context"
	"strconv"
	"time"
)

// FROZEN envelope contract — both producer planes and this consumer MUST agree
// on these field names and types. A drift here silently drops or mis-counts.
const (
	fieldTenantID = "tenant_id"       // string
	fieldMetric   = "metric"          // query.count|query.rows|write.rows|...
	fieldQty      = "qty"             // integer, encoded as string
	fieldTs       = "ts"              // unix ms, encoded as string
	fieldWindowMs = "window_ms"       // window size in ms, encoded as string
	fieldIdemKey  = "idempotency_key" // lower-hex sha256("tenant|metric|window_start_ms")
)

// meteringErr is the package's const error type, so sentinels are typed
// constants (no package-level var) while preserving errors.Is matching.
type meteringErr string

func (e meteringErr) Error() string { return string(e) }

// errBadEntry marks a malformed stream entry (skipped, not fatal — at-least-once
// delivery means a poison entry must never wedge the consumer).
const errBadEntry meteringErr = "metering: malformed usage entry"

// execer is the minimal Postgres surface the store needs: one parameterized
// statement. pg.Postgres.AdminExec satisfies it (the consumer writes as the
// privileged control-plane role, which is BYPASSRLS), and a fake satisfies it in
// unit tests — no live database required to prove the dedup contract.
type execer interface {
	AdminExec(ctx context.Context, sql string, args ...any) error
}

// usageRecord is the parsed, validated form of one `usage.events` stream entry.
type usageRecord struct {
	TenantID    string
	Metric      string
	Qty         int64
	WindowStart time.Time
	IdemKey     string
}

// Store is the idempotent writer into public.tenant_usage.
type Store struct {
	db execer
}

// NewStore wraps the privileged Postgres handle.
func NewStore(db execer) *Store { return &Store{db: db} }

// upsertSQL is the idempotent ingest. ON CONFLICT (idempotency_key) DO NOTHING
// is the FROZEN dedup rule: a re-delivered identical window (same
// tenant|metric|window_start_ms) is a no-op, never a double-count. Because the
// idempotency_key already encodes the full windowed qty (the data plane flushes
// the cumulative window total, not per-op deltas), a second delivery of the same
// window carries the same total — so DO NOTHING is correct (not DO UPDATE += ).
const upsertSQL = `
INSERT INTO public.tenant_usage (tenant_id, metric, window_start, qty, idempotency_key, updated_at)
VALUES ($1, $2, $3, $4, $5, now())
ON CONFLICT (idempotency_key) DO NOTHING`

// Upsert validates and writes one record. A malformed record is rejected with
// errBadEntry (the caller skips + acks it so a poison entry can't wedge the
// stream); a DB error is returned so the caller leaves the entry un-acked for
// redelivery.
func (s *Store) Upsert(ctx context.Context, fields map[string]any) error {
	rec, err := parseRecord(fields)
	if err != nil {
		return err
	}
	return s.db.AdminExec(ctx, upsertSQL,
		rec.TenantID, rec.Metric, rec.WindowStart, rec.Qty, rec.IdemKey)
}

// parseRecord turns the raw Redis-stream field map into a validated usageRecord.
// Redis stream values arrive as strings; qty and window_start_ms are decimal
// strings per the frozen contract. window_start is derived from ts and
// window_ms (window_start_ms = ts - (ts mod window_ms)) so the consumer never
// trusts a caller-supplied window_start — it reconstructs it from the same
// inputs that built the idempotency_key, keeping the two consistent.
func parseRecord(fields map[string]any) (usageRecord, error) {
	var rec usageRecord
	rec.TenantID = strField(fields, fieldTenantID)
	rec.Metric = strField(fields, fieldMetric)
	rec.IdemKey = strField(fields, fieldIdemKey)
	if rec.TenantID == "" || rec.Metric == "" || rec.IdemKey == "" {
		return rec, errBadEntry
	}

	qty, err := strconv.ParseInt(strField(fields, fieldQty), 10, 64)
	if err != nil || qty < 0 {
		return rec, errBadEntry
	}
	rec.Qty = qty

	tsMs, err := strconv.ParseInt(strField(fields, fieldTs), 10, 64)
	if err != nil || tsMs <= 0 {
		return rec, errBadEntry
	}
	windowMs, err := strconv.ParseInt(strField(fields, fieldWindowMs), 10, 64)
	if err != nil || windowMs <= 0 {
		return rec, errBadEntry
	}
	windowStartMs := tsMs - (tsMs % windowMs)
	rec.WindowStart = time.UnixMilli(windowStartMs).UTC()
	return rec, nil
}

// strField reads a stream field as a string. Redis go-client decodes XReadGroup
// values as `string`, but tolerate []byte too for fakes/other producers.
func strField(fields map[string]any, key string) string {
	v, ok := fields[key]
	if !ok || v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return t
	case []byte:
		return string(t)
	default:
		return ""
	}
}
