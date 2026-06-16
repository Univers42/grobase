package metering

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers the metering read-back route onto the shared mux (B1c).
//
// This mirrors internal/webhooks/handler.go and internal/functriggers/handler.go
// EXACTLY: Go 1.22 net/http ServeMux "GET /v1/..." patterns with a {id} path
// param, and the SAME admin/self auth + tenant-scoping that GET /v1/tenants/{id}
// uses (tenants.tokenOrSelf): a control-plane service token authorises any
// tenant, otherwise the caller may only read its OWN tenant when a matching
// X-Baas-Tenant-Id / X-Tenant-Id header equals the {id} in the path.
//
// Read-only and purely additive: it queries public.tenant_usage (migration 040).
// No new flag gates the READ path — when metering is OFF the table is simply
// empty and the endpoint returns empty aggregates, so route addition changes no
// existing path (that IS the parity story). Adding the route never creates,
// emits, or schedules anything.
func Mount(mux *http.ServeMux, db *shared.Postgres, serviceToken string) {
	rt := &readRoutes{reader: &Reader{db: pgPool{db: db}}, serviceToken: serviceToken}
	mux.HandleFunc("GET /v1/tenants/{id}/usage", rt.usage)
}

type readRoutes struct {
	reader       *Reader
	serviceToken string
}

// usage returns the summed per-metric usage for one tenant over an optional
// [from,to) window, optionally narrowed to a single metric. Every byte of the
// response is derived from public.tenant_usage rows the SQL scoped to this
// tenant — the read NEVER trusts a self-reported total.
func (rt *readRoutes) usage(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}

	q := r.URL.Query()
	metric := strings.TrimSpace(q.Get("metric"))

	from, ok := parseWindowBound(w, q.Get("from"), "from")
	if !ok {
		return
	}
	to, ok := parseWindowBound(w, q.Get("to"), "to")
	if !ok {
		return
	}

	out, err := rt.reader.Aggregate(r.Context(), tenantID, metric, from, to)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// tokenOrSelf authorises read of a tenant's usage by either a control-plane
// service token (admin) or a matching X-Baas-Tenant-Id / X-Tenant-Id header (a
// tenant reading its own usage) — byte-identical to tenants.routes.tokenOrSelf,
// which guards GET /v1/tenants/{id}. The ISOLATION guarantee is enforced twice:
// here at the edge (a tenant can only ASK for its own id) and again in the SQL
// (tenant_id is always bound in the WHERE), atop the RLS policy on the table.
func (rt *readRoutes) tokenOrSelf(w http.ResponseWriter, r *http.Request, id string) bool {
	if shared.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if r.Header.Get("X-Baas-Tenant-Id") == id || r.Header.Get("X-Tenant-Id") == id {
		return true
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"service token or matching tenant header required")
	return false
}

// parseWindowBound parses an optional ?from / ?to value. An empty value is a
// valid "unbounded" side (zero time). A present value is accepted as either an
// RFC3339 timestamp or a unix-millisecond integer; anything else is a 400 so a
// malformed filter is never silently ignored.
func parseWindowBound(w http.ResponseWriter, raw, field string) (time.Time, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}, true
	}
	if t, err := time.Parse(time.RFC3339, raw); err == nil {
		return t.UTC(), true
	}
	if ms, err := strconv.ParseInt(raw, 10, 64); err == nil && ms >= 0 {
		return time.UnixMilli(ms).UTC(), true
	}
	shared.WriteError(w, http.StatusBadRequest, "validation_error",
		"invalid "+field+": want RFC3339 or unix-ms")
	return time.Time{}, false
}

// rows is the minimal cursor surface the Reader scans. pgx.Rows (returned by
// shared.Postgres.AdminQuery) satisfies it; a fake satisfies it in unit tests so
// the aggregation + isolation contract needs no live database.
type rows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
	Close()
}

// querier is the minimal Postgres read surface the Reader needs.
// shared.Postgres (AdminQuery — privileged, BYPASSRLS) satisfies it via the
// adapter below; a fake satisfies it directly in unit tests.
type querier interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (rows, error)
}

// pgPool adapts shared.Postgres (whose AdminQuery returns pgx.Rows) to querier
// (whose AdminQuery returns the narrow rows interface). pgx.Rows already has
// Next/Scan/Err/Close, so the adapt is purely a return-type widen.
type pgPool struct{ db *shared.Postgres }

func (p pgPool) AdminQuery(ctx context.Context, sql string, args ...any) (rows, error) {
	return p.db.AdminQuery(ctx, sql, args...)
}

// Reader sums public.tenant_usage rows for one tenant. It is a thin read-only
// twin of webhooks.Service / functriggers.Service — one query, no mutation.
type Reader struct {
	db querier
}

// MetricAgg is one metric's summed usage over the selected window.
type MetricAgg struct {
	Metric      string `json:"metric"`
	Qty         int64  `json:"qty"`
	WindowCount int64  `json:"window_count"`
}

// Window echoes the resolved [from,to) bounds (RFC3339, empty = unbounded side).
type Window struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// UsageResponse is the JSON returned by GET /v1/tenants/{id}/usage.
type UsageResponse struct {
	TenantID string      `json:"tenant_id"`
	Window   Window      `json:"window"`
	Metrics  []MetricAgg `json:"metrics"`
	TotalQty int64       `json:"total_qty"`
}

// aggregateSQL sums qty (and counts windows) per metric for ONE tenant over an
// optional [from,to) window, optionally narrowed to one metric.
//
// $1 tenant_id is ALWAYS bound (defense-in-depth atop the RLS policy on
// tenant_usage): the read can NEVER see another tenant's rows even if RLS were
// ever misconfigured or the caller is the BYPASSRLS service role. The metric /
// from / to params are nullable — a NULL means "no filter on that dimension":
//
//	($2 IS NULL OR metric       =  $2)
//	($3 IS NULL OR window_start >= $3)
//	($4 IS NULL OR window_start <  $4)   -- half-open [from,to)
const aggregateSQL = `
SELECT metric, COALESCE(SUM(qty), 0)::bigint AS qty, COUNT(*)::bigint AS window_count
  FROM public.tenant_usage
 WHERE tenant_id = $1
   AND ($2::text        IS NULL OR metric       =  $2)
   AND ($3::timestamptz IS NULL OR window_start >= $3)
   AND ($4::timestamptz IS NULL OR window_start <  $4)
 GROUP BY metric
 ORDER BY metric`

// Aggregate runs aggregateSQL and assembles the response. metric=="" / zero
// from / zero to each disable that filter (passed as SQL NULL).
func (r *Reader) Aggregate(ctx context.Context, tenantID, metric string, from, to time.Time) (UsageResponse, error) {
	resp := UsageResponse{
		TenantID: tenantID,
		Window:   Window{From: rfc3339OrEmpty(from), To: rfc3339OrEmpty(to)},
		Metrics:  make([]MetricAgg, 0),
	}
	rows, err := r.db.AdminQuery(ctx, aggregateSQL,
		tenantID, nullableStr(metric), nullableTime(from), nullableTime(to))
	if err != nil {
		return resp, err
	}
	defer rows.Close()
	for rows.Next() {
		var m MetricAgg
		if err := rows.Scan(&m.Metric, &m.Qty, &m.WindowCount); err != nil {
			return resp, err
		}
		resp.Metrics = append(resp.Metrics, m)
		resp.TotalQty += m.Qty
	}
	if err := rows.Err(); err != nil {
		return resp, err
	}
	return resp, nil
}

// nullableStr maps an empty filter to SQL NULL (no filter).
func nullableStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// nullableTime maps a zero time to SQL NULL (unbounded side).
func nullableTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC()
}

// rfc3339OrEmpty renders a bound for the echoed window ("" when unbounded).
func rfc3339OrEmpty(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}
