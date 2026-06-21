/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_test.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:47:24 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:47:25 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package metering

import (
	"context"
	"errors"
	"testing"
	"time"
)

// fakeDB models public.tenant_usage as a map keyed by idempotency_key (the PK),
// applying ON CONFLICT (idempotency_key) DO NOTHING. It is the in-memory twin of
// the upsertSQL contract, so the dedup proof needs no live Postgres.
type fakeDB struct {
	rows  map[string]int64 // idempotency_key -> qty
	execs int              // total AdminExec calls (proves we DID attempt twice)
}

func newFakeDB() *fakeDB { return &fakeDB{rows: map[string]int64{}} }

// AdminExec implements execer with DO NOTHING semantics on the idempotency_key.
// upsertSQL arg order: tenant_id, metric, window_start, qty, idempotency_key.
func (f *fakeDB) AdminExec(_ context.Context, _ string, args ...any) error {
	f.execs++
	if len(args) != 5 {
		return errors.New("unexpected arg count")
	}
	qty, _ := args[3].(int64)
	key, _ := args[4].(string)
	if _, exists := f.rows[key]; exists {
		return nil // ON CONFLICT DO NOTHING
	}
	f.rows[key] = qty
	return nil
}

func entry(tenant, metric, qty, ts, windowMs, idem string) map[string]any {
	return map[string]any{
		fieldTenantID: tenant,
		fieldMetric:   metric,
		fieldQty:      qty,
		fieldTs:       ts,
		fieldWindowMs: windowMs,
		fieldIdemKey:  idem,
	}
}

// TestUpsertDedup is the B1b done-when: two inserts with the SAME idempotency_key
// land exactly one row (a re-delivered identical window must NOT double-count).
func TestUpsertDedup(t *testing.T) {
	db := newFakeDB()
	s := NewStore(db)
	ctx := context.Background()

	e := entry("tenant-a", "query.count", "7", "1700000000000", "60000", "dup-key")
	if err := s.Upsert(ctx, e); err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	if err := s.Upsert(ctx, e); err != nil {
		t.Fatalf("second upsert: %v", err)
	}

	if db.execs != 2 {
		t.Errorf("expected 2 exec attempts, got %d", db.execs)
	}
	if len(db.rows) != 1 {
		t.Fatalf("expected exactly 1 row after duplicate ingest, got %d", len(db.rows))
	}
	if got := db.rows["dup-key"]; got != 7 {
		t.Errorf("qty = %d, want 7 (no double-count)", got)
	}
}

// TestUpsertDistinctKeys: distinct windows produce distinct rows.
func TestUpsertDistinctKeys(t *testing.T) {
	db := newFakeDB()
	s := NewStore(db)
	ctx := context.Background()

	for _, e := range []map[string]any{
		entry("tenant-a", "query.count", "3", "1700000000000", "60000", "k1"),
		entry("tenant-a", "query.rows", "10", "1700000000000", "60000", "k2"),
		entry("tenant-b", "write.rows", "1", "1700000000000", "60000", "k3"),
	} {
		if err := s.Upsert(ctx, e); err != nil {
			t.Fatalf("upsert: %v", err)
		}
	}
	if len(db.rows) != 3 {
		t.Errorf("expected 3 distinct rows, got %d", len(db.rows))
	}
}

// TestWindowStartDerivation: window_start is reconstructed as ts - (ts mod
// window_ms) — the consumer never trusts a caller-supplied window_start, it
// derives it from the same inputs that built the idempotency_key.
func TestWindowStartDerivation(t *testing.T) {
	// ts = 1700000123456, window = 60000ms -> floor to 1700000100000.
	rec, err := parseRecord(entry("t", "query.count", "1", "1700000123456", "60000", "k"))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	want := time.UnixMilli(1700000100000).UTC()
	if !rec.WindowStart.Equal(want) {
		t.Errorf("window_start = %v, want %v", rec.WindowStart, want)
	}
}

// TestParseRejectsMalformed: missing/invalid fields are errBadEntry (skipped +
// acked by the consumer so a poison entry can't wedge the group).
func TestParseRejectsMalformed(t *testing.T) {
	bad := []map[string]any{
		entry("", "query.count", "1", "1700000000000", "60000", "k"),   // no tenant
		entry("t", "", "1", "1700000000000", "60000", "k"),             // no metric
		entry("t", "query.count", "x", "1700000000000", "60000", "k"),  // bad qty
		entry("t", "query.count", "-1", "1700000000000", "60000", "k"), // negative qty
		entry("t", "query.count", "1", "0", "60000", "k"),              // bad ts
		entry("t", "query.count", "1", "1700000000000", "0", "k"),      // zero window
		entry("t", "query.count", "1", "1700000000000", "60000", ""),   // no idem key
	}
	for i, e := range bad {
		if _, err := parseRecord(e); !errors.Is(err, errBadEntry) {
			t.Errorf("case %d: expected errBadEntry, got %v", i, err)
		}
	}
}
