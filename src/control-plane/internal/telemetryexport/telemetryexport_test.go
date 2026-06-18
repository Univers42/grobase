package telemetryexport

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"
	"time"
)

// discard sinks log output in tests.
type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

func testLogger() *slog.Logger { return slog.New(slog.NewTextHandler(discard{}, nil)) }

/* ─────── fakes ─────── */

// fakeTarget is one seeded targets row.
type fakeTarget struct {
	tenantID, endpoint, authHeader, format string
	cursor                                 time.Time
}

// fakeUsage is one seeded tenant_usage row.
type fakeUsage struct {
	tenantID, metric string
	windowStart      time.Time
	qty              int64
}

// fakeDB serves the two SELECTs (targets list, per-tenant usage) and records the
// cursor advances. tenantUsageSinceSQL is scoped by $1=tenant_id and $2=cursor, so
// the fake enforces THE SAME scope the real SQL does — the unit test then proves
// the exporter never crosses tenants even when the store holds another tenant's rows.
type fakeDB struct {
	targets  []fakeTarget
	usage    []fakeUsage
	advanced map[string]time.Time
}

func (f *fakeDB) AdminQuery(_ context.Context, sql string, args ...any) (rows, error) {
	if strings.Contains(sql, "tenant_telemetry_targets") {
		return &targetRows{data: f.targets}, nil
	}
	// per-tenant usage scan: filter to $1=tenant_id, $2=cursor (exclusive).
	tid := args[0].(string)
	cur := args[1].(time.Time)
	var out []fakeUsage
	for _, u := range f.usage {
		if u.tenantID == tid && u.windowStart.After(cur) {
			out = append(out, u)
		}
	}
	return &usageRows{data: out}, nil
}

func (f *fakeDB) AdminExec(_ context.Context, _ string, args ...any) error {
	if f.advanced == nil {
		f.advanced = map[string]time.Time{}
	}
	f.advanced[args[0].(string)] = args[1].(time.Time)
	return nil
}

type targetRows struct {
	data []fakeTarget
	i    int
	cur  fakeTarget
}

func (r *targetRows) Next() bool {
	if r.i >= len(r.data) {
		return false
	}
	r.cur = r.data[r.i]
	r.i++
	return true
}

func (r *targetRows) Scan(dest ...any) error {
	*dest[0].(*string) = r.cur.tenantID
	*dest[1].(*string) = r.cur.endpoint
	*dest[2].(*string) = r.cur.authHeader
	*dest[3].(*string) = r.cur.format
	*dest[4].(*time.Time) = r.cur.cursor
	return nil
}
func (r *targetRows) Err() error { return nil }
func (r *targetRows) Close()     {}

type usageRows struct {
	data []fakeUsage
	i    int
	cur  fakeUsage
}

func (r *usageRows) Next() bool {
	if r.i >= len(r.data) {
		return false
	}
	r.cur = r.data[r.i]
	r.i++
	return true
}

func (r *usageRows) Scan(dest ...any) error {
	*dest[0].(*string) = r.cur.metric
	*dest[1].(*time.Time) = r.cur.windowStart
	*dest[2].(*int64) = r.cur.qty
	return nil
}
func (r *usageRows) Err() error { return nil }
func (r *usageRows) Close()     {}

// captureSink records every delivery as (endpoint, contentType, body) so the test
// can assert WHICH endpoint received WHICH tenant's data.
type delivery struct {
	endpoint, authHeader, contentType, body string
}
type captureSink struct{ deliveries []delivery }

func (c *captureSink) Deliver(_ context.Context, endpoint, authHeader, contentType string, body []byte) error {
	c.deliveries = append(c.deliveries, delivery{endpoint, authHeader, contentType, string(body)})
	return nil
}

/* ─────── tests ─────── */

func newExporter(db exportDB, sink sink) *Exporter {
	return &Exporter{
		log:       testLogger(),
		db:        db,
		sink:      sink,
		enabled:   true,
		batchRows: 500,
	}
}

// TestPerTenantRoutingNoLeak is the LOAD-BEARING isolation test: two tenants T and
// U each have their OWN endpoint, and the store holds BOTH tenants' usage. After one
// sweep, T's endpoint must receive ONLY T's data (tenant_id=T, never U's qty) and
// U's endpoint must receive ONLY U's data — proving a tenant's telemetry can never
// reach another tenant's collector.
func TestPerTenantRoutingNoLeak(t *testing.T) {
	w1 := time.Date(2026, 6, 14, 10, 0, 0, 0, time.UTC)
	epoch := time.Unix(0, 0).UTC()
	db := &fakeDB{
		targets: []fakeTarget{
			{tenantID: "T", endpoint: "http://sink-T/v1/logs", authHeader: "Bearer tok-T", format: "ndjson", cursor: epoch},
			{tenantID: "U", endpoint: "http://sink-U/v1/logs", authHeader: "Bearer tok-U", format: "ndjson", cursor: epoch},
		},
		usage: []fakeUsage{
			{tenantID: "T", metric: "query.count", windowStart: w1, qty: 42},
			{tenantID: "U", metric: "query.count", windowStart: w1, qty: 9999}, // U's secret qty — must NEVER reach T
		},
	}
	cs := &captureSink{}
	e := newExporter(db, cs)
	e.exportOnce(context.Background())

	if len(cs.deliveries) != 2 {
		t.Fatalf("expected 2 deliveries (one per tenant), got %d", len(cs.deliveries))
	}
	byEndpoint := map[string]delivery{}
	for _, d := range cs.deliveries {
		byEndpoint[d.endpoint] = d
	}
	dT, okT := byEndpoint["http://sink-T/v1/logs"]
	dU, okU := byEndpoint["http://sink-U/v1/logs"]
	if !okT || !okU {
		t.Fatalf("each tenant's endpoint must receive exactly one delivery; got endpoints %v", byEndpoint)
	}
	// T's sink: carries tenant_id=T and 42; NEVER U's tenant_id or U's 9999.
	if !strings.Contains(dT.body, `"tenant_id":"T"`) || !strings.Contains(dT.body, `"qty":42`) {
		t.Fatalf("T's sink missing T's attributed data: %s", dT.body)
	}
	if strings.Contains(dT.body, "9999") || strings.Contains(dT.body, `"tenant_id":"U"`) {
		t.Fatalf("CROSS-TENANT LEAK: U's telemetry reached T's sink: %s", dT.body)
	}
	// U's sink: carries U's data; NEVER T's.
	if !strings.Contains(dU.body, `"tenant_id":"U"`) || !strings.Contains(dU.body, "9999") {
		t.Fatalf("U's sink missing U's data: %s", dU.body)
	}
	if strings.Contains(dU.body, `"tenant_id":"T"`) || strings.Contains(dU.body, `"qty":42`) {
		t.Fatalf("CROSS-TENANT LEAK: T's telemetry reached U's sink: %s", dU.body)
	}
	// The per-tenant auth header is routed correctly too.
	if dT.authHeader != "Bearer tok-T" || dU.authHeader != "Bearer tok-U" {
		t.Fatalf("auth header crossed tenants: T=%q U=%q", dT.authHeader, dU.authHeader)
	}
	// Each tenant's cursor advanced to its own newest window.
	if db.advanced["T"] != w1 || db.advanced["U"] != w1 {
		t.Fatalf("cursors not advanced per tenant: %v", db.advanced)
	}
}

// TestOTLPAttributesTenant: the OTLP wire shape carries tenant_id as BOTH a resource
// attribute and a per-record attribute, and is valid JSON.
func TestOTLPAttributesTenant(t *testing.T) {
	w1 := time.Date(2026, 6, 14, 10, 0, 0, 0, time.UTC)
	body := newExporter(nil, nil).buildOTLP("T", []usageRow{{metric: "query.count", windowStart: w1, qty: 7}})
	var env map[string]any
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("OTLP body is not valid JSON: %v\n%s", err, body)
	}
	s := string(body)
	if !strings.Contains(s, `"tenant_id"`) || !strings.Contains(s, `"T"`) {
		t.Fatalf("OTLP body does not attribute tenant_id=T: %s", s)
	}
	if !strings.Contains(s, "resourceLogs") || !strings.Contains(s, "logRecords") {
		t.Fatalf("OTLP body is not an ExportLogsServiceRequest envelope: %s", s)
	}
}

// TestNoNewWindowsNoDelivery: a tenant whose cursor is already at/after its newest
// window exports NOTHING (no delivery, no cursor write) — idempotent re-runs.
func TestNoNewWindowsNoDelivery(t *testing.T) {
	w1 := time.Date(2026, 6, 14, 10, 0, 0, 0, time.UTC)
	db := &fakeDB{
		targets: []fakeTarget{{tenantID: "T", endpoint: "http://sink-T", format: "ndjson", cursor: w1}},
		usage:   []fakeUsage{{tenantID: "T", metric: "query.count", windowStart: w1, qty: 42}},
	}
	cs := &captureSink{}
	e := newExporter(db, cs)
	if got := e.exportOnce(context.Background()); got != 0 {
		t.Fatalf("expected 0 tenants exported (cursor at newest window), got %d", got)
	}
	if len(cs.deliveries) != 0 {
		t.Fatalf("expected NO deliveries when nothing is newer than the cursor, got %d", len(cs.deliveries))
	}
}

// TestDisabledRunIsNoOp: with the flag OFF, Run returns immediately and never lists
// targets, reads usage, delivers, or advances a cursor — the parity invariant.
func TestDisabledRunIsNoOp(t *testing.T) {
	w1 := time.Date(2026, 6, 14, 10, 0, 0, 0, time.UTC)
	db := &fakeDB{
		targets: []fakeTarget{{tenantID: "T", endpoint: "http://sink-T", format: "ndjson", cursor: time.Unix(0, 0)}},
		usage:   []fakeUsage{{tenantID: "T", metric: "query.count", windowStart: w1, qty: 42}},
	}
	cs := &captureSink{}
	e := &Exporter{log: testLogger(), db: db, sink: cs, enabled: false, batchRows: 500, interval: time.Hour}
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // pre-cancelled: a disabled Run must return WITHOUT touching anything anyway
	e.Run(ctx)
	if len(cs.deliveries) != 0 {
		t.Fatalf("disabled exporter delivered %d batches — NOT parity", len(cs.deliveries))
	}
	if len(db.advanced) != 0 {
		t.Fatalf("disabled exporter advanced %d cursors — NOT parity", len(db.advanced))
	}
}
