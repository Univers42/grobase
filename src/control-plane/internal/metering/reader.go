package metering

import (
	"context"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

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
		tenantID, nullableStr(metric), shared.NullableTime(from), shared.NullableTime(to))
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

// rfc3339OrEmpty renders a bound for the echoed window ("" when unbounded).
func rfc3339OrEmpty(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}
