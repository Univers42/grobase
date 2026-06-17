package metering

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeRow is one tenant_usage row as the fake store holds it.
type fakeRow struct {
	tenantID    string
	metric      string
	windowStart time.Time
	qty         int64
	idemKey     string
}

// fakeStore is an in-memory twin of public.tenant_usage that re-implements the
// aggregateSQL contract: tenant_id is ALWAYS bound, and the metric/from/to
// filters are NULL-skippable. It returns the GROUP BY metric, SUM(qty),
// COUNT(*) projection ordered by metric — so the unit test asserts the exact
// aggregation + ISOLATION the SQL must perform, with no live Postgres.
type fakeStore struct {
	rows  []fakeRow
	calls int
}

func (f *fakeStore) AdminQuery(_ context.Context, _ string, args ...any) (rows, error) {
	f.calls++
	// arg order mirrors aggregateSQL: tenant_id, metric|nil, from|nil, to|nil.
	tenant, _ := args[0].(string)
	var metric *string
	if m, ok := args[1].(string); ok {
		metric = &m
	}
	var from, to *time.Time
	if t, ok := args[2].(time.Time); ok {
		from = &t
	}
	if t, ok := args[3].(time.Time); ok {
		to = &t
	}

	agg := map[string]*MetricAgg{}
	var order []string
	for _, r := range f.rows {
		// tenant_id = $1 — the load-bearing isolation predicate.
		if r.tenantID != tenant {
			continue
		}
		if metric != nil && r.metric != *metric {
			continue
		}
		if from != nil && r.windowStart.Before(*from) {
			continue
		}
		if to != nil && !r.windowStart.Before(*to) { // half-open [from,to)
			continue
		}
		a, ok := agg[r.metric]
		if !ok {
			a = &MetricAgg{Metric: r.metric}
			agg[r.metric] = a
			order = append(order, r.metric)
		}
		a.Qty += r.qty
		a.WindowCount++
	}
	// ORDER BY metric.
	for i := 0; i < len(order); i++ {
		for j := i + 1; j < len(order); j++ {
			if order[j] < order[i] {
				order[i], order[j] = order[j], order[i]
			}
		}
	}
	out := make([]MetricAgg, 0, len(order))
	for _, m := range order {
		out = append(out, *agg[m])
	}
	return &fakeRows{data: out}, nil
}

// fakeRows is the cursor over the aggregated projection.
type fakeRows struct {
	data []MetricAgg
	i    int
	cur  MetricAgg
}

func (r *fakeRows) Next() bool {
	if r.i >= len(r.data) {
		return false
	}
	r.cur = r.data[r.i]
	r.i++
	return true
}

func (r *fakeRows) Scan(dest ...any) error {
	*(dest[0].(*string)) = r.cur.Metric
	*(dest[1].(*int64)) = r.cur.Qty
	*(dest[2].(*int64)) = r.cur.WindowCount
	return nil
}

func (r *fakeRows) Err() error { return nil }
func (r *fakeRows) Close()     {}

// seeded mirrors the gate's independently-seeded SQL truth: tenant T across 2
// windows x 2 metrics, plus a row for a DIFFERENT tenant T2 (the isolation foil).
func seeded() *fakeStore {
	w1 := time.Date(2026, 6, 14, 10, 0, 0, 0, time.UTC)
	w2 := time.Date(2026, 6, 14, 11, 0, 0, 0, time.UTC)
	return &fakeStore{rows: []fakeRow{
		{"T", "query.count", w1, 3, "k1"},
		{"T", "query.count", w2, 7, "k2"},
		{"T", "write.rows", w1, 11, "k3"},
		{"T", "write.rows", w2, 13, "k4"},
		// T2's rows must NEVER appear in a response for T.
		{"T2", "query.count", w1, 9999, "k5"},
		{"T2", "write.rows", w2, 8888, "k6"},
	}}
}

func newRoutes(store *fakeStore, token string) *readRoutes {
	return &readRoutes{reader: &Reader{db: store}, serviceToken: token}
}

// doGet exercises the real handler (mux + tokenOrSelf + Aggregate) end to end.
func doGet(rt *readRoutes, target string, headers map[string]string) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/tenants/{id}/usage", rt.usage)
	req := httptest.NewRequest(http.MethodGet, target, nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func decode(t *testing.T, rec *httptest.ResponseRecorder) UsageResponse {
	t.Helper()
	var out UsageResponse
	if err := json.NewDecoder(rec.Body).Decode(&out); err != nil {
		t.Fatalf("decode response: %v (body=%s)", err, rec.Body.String())
	}
	return out
}

func metricQty(out UsageResponse, metric string) (int64, bool) {
	for _, m := range out.Metrics {
		if m.Metric == metric {
			return m.Qty, true
		}
	}
	return 0, false
}

// POSITIVE: summed qty per metric == seeded truth, total_qty == grand sum.
func TestUsage_Positive_SumPerMetricAndTotal(t *testing.T) {
	rt := newRoutes(seeded(), "svc-token")
	rec := doGet(rt, "/v1/tenants/T/usage", map[string]string{"X-Service-Token": "svc-token"})
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	out := decode(t, rec)
	if out.TenantID != "T" {
		t.Fatalf("tenant_id = %q, want T", out.TenantID)
	}
	if q, _ := metricQty(out, "query.count"); q != 3+7 {
		t.Fatalf("query.count qty = %d, want %d (seeded truth)", q, 3+7)
	}
	if q, _ := metricQty(out, "write.rows"); q != 11+13 {
		t.Fatalf("write.rows qty = %d, want %d (seeded truth)", q, 11+13)
	}
	if out.TotalQty != 3+7+11+13 {
		t.Fatalf("total_qty = %d, want %d (grand sum)", out.TotalQty, 3+7+11+13)
	}
	for _, m := range out.Metrics {
		if m.WindowCount != 2 {
			t.Fatalf("metric %s window_count = %d, want 2", m.Metric, m.WindowCount)
		}
	}
}

// ISOLATION (load-bearing): the response for T must NEVER include T2's qty.
func TestUsage_Isolation_NeverLeaksOtherTenant(t *testing.T) {
	rt := newRoutes(seeded(), "svc-token")
	rec := doGet(rt, "/v1/tenants/T/usage", map[string]string{"X-Service-Token": "svc-token"})
	out := decode(t, rec)
	// T2's query.count is 9999 and write.rows is 8888; neither may appear.
	if q, _ := metricQty(out, "query.count"); q == 9999 || q > 10+8888 {
		t.Fatalf("ISOLATION BREACH: query.count qty %d includes T2's rows", q)
	}
	if out.TotalQty >= 8888 {
		t.Fatalf("ISOLATION BREACH: total_qty %d includes T2's 8888/9999 rows", out.TotalQty)
	}
	// And T2's own read must only show T2's truth, never T's.
	rec2 := doGet(rt, "/v1/tenants/T2/usage", map[string]string{"X-Service-Token": "svc-token"})
	out2 := decode(t, rec2)
	if out2.TotalQty != 9999+8888 {
		t.Fatalf("T2 total_qty = %d, want %d (only T2's own rows)", out2.TotalQty, 9999+8888)
	}
}

// FILTER: ?metric= narrows to one metric.
func TestUsage_Filter_Metric(t *testing.T) {
	rt := newRoutes(seeded(), "svc-token")
	rec := doGet(rt, "/v1/tenants/T/usage?metric=query.count",
		map[string]string{"X-Service-Token": "svc-token"})
	out := decode(t, rec)
	if len(out.Metrics) != 1 || out.Metrics[0].Metric != "query.count" {
		t.Fatalf("metric filter returned %+v, want only query.count", out.Metrics)
	}
	if out.TotalQty != 3+7 {
		t.Fatalf("filtered total_qty = %d, want %d", out.TotalQty, 3+7)
	}
}

// FILTER: ?from/&to window (half-open) narrows correctly — only window 1.
func TestUsage_Filter_Window(t *testing.T) {
	rt := newRoutes(seeded(), "svc-token")
	// [10:00, 11:00) selects ONLY window 1 (w2 at 11:00 is excluded).
	from := "2026-06-14T10:00:00Z"
	to := "2026-06-14T11:00:00Z"
	rec := doGet(rt, "/v1/tenants/T/usage?from="+from+"&to="+to,
		map[string]string{"X-Service-Token": "svc-token"})
	out := decode(t, rec)
	if q, _ := metricQty(out, "query.count"); q != 3 {
		t.Fatalf("windowed query.count = %d, want 3 (w1 only)", q)
	}
	if q, _ := metricQty(out, "write.rows"); q != 11 {
		t.Fatalf("windowed write.rows = %d, want 11 (w1 only)", q)
	}
	if out.TotalQty != 3+11 {
		t.Fatalf("windowed total_qty = %d, want %d", out.TotalQty, 3+11)
	}
}

// FILTER: unix-ms bounds are accepted equivalently to RFC3339.
func TestUsage_Filter_WindowUnixMs(t *testing.T) {
	rt := newRoutes(seeded(), "svc-token")
	fromMs := time.Date(2026, 6, 14, 10, 0, 0, 0, time.UTC).UnixMilli()
	toMs := time.Date(2026, 6, 14, 11, 0, 0, 0, time.UTC).UnixMilli()
	rec := doGet(rt,
		"/v1/tenants/T/usage?from="+itoa(fromMs)+"&to="+itoa(toMs),
		map[string]string{"X-Service-Token": "svc-token"})
	out := decode(t, rec)
	if out.TotalQty != 3+11 {
		t.Fatalf("unix-ms windowed total_qty = %d, want %d", out.TotalQty, 3+11)
	}
}

// AUTH: self-read via matching tenant header is allowed; mismatched is 401.
func TestUsage_Auth_SelfHeader(t *testing.T) {
	rt := newRoutes(seeded(), "svc-token")
	// matching X-Baas-Tenant-Id → allowed.
	rec := doGet(rt, "/v1/tenants/T/usage", map[string]string{"X-Baas-Tenant-Id": "T"})
	if rec.Code != http.StatusOK {
		t.Fatalf("self-read with matching header: want 200, got %d", rec.Code)
	}
	// A tenant asking for ANOTHER tenant's usage with its own header → 401.
	rec2 := doGet(rt, "/v1/tenants/T2/usage", map[string]string{"X-Baas-Tenant-Id": "T"})
	if rec2.Code != http.StatusUnauthorized {
		t.Fatalf("cross-tenant self-read: want 401, got %d", rec2.Code)
	}
	// No token, no header → 401.
	rec3 := doGet(rt, "/v1/tenants/T/usage", nil)
	if rec3.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated: want 401, got %d", rec3.Code)
	}
}

// VALIDATION: a malformed window bound is a 400 (never silently ignored).
func TestUsage_BadWindow_400(t *testing.T) {
	rt := newRoutes(seeded(), "svc-token")
	rec := doGet(rt, "/v1/tenants/T/usage?from=not-a-time",
		map[string]string{"X-Service-Token": "svc-token"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("bad from: want 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

// EMPTY: a tenant with no usage rows (metering OFF parity) returns empty
// aggregates and total_qty 0 — never an error.
func TestUsage_EmptyTenant_ParityShape(t *testing.T) {
	rt := newRoutes(seeded(), "svc-token")
	rec := doGet(rt, "/v1/tenants/UNKNOWN/usage",
		map[string]string{"X-Service-Token": "svc-token"})
	if rec.Code != http.StatusOK {
		t.Fatalf("empty tenant: want 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	out := decode(t, rec)
	if len(out.Metrics) != 0 || out.TotalQty != 0 {
		t.Fatalf("empty tenant: want zero metrics/total, got %+v", out)
	}
	if !strings.Contains(body, `"metrics":[]`) {
		t.Fatalf("empty metrics should serialize as [], got %s", body)
	}
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
