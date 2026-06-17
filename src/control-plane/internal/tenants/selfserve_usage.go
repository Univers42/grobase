package tenants

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// MetricAgg is one metric's summed usage over the selected window (mirrors
// metering.MetricAgg so the /me/usage body is shape-identical to {id}/usage).
type MetricAgg struct {
	Metric      string `json:"metric"`
	Qty         int64  `json:"qty"`
	WindowCount int64  `json:"window_count"`
}

// UsageWindow echoes the resolved [from,to) bounds (RFC3339, "" = unbounded).
type UsageWindow struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// UsageResponse is the body of GET /v1/tenants/me/usage (shape-identical to
// metering.UsageResponse).
type UsageResponse struct {
	TenantID string      `json:"tenant_id"`
	Window   UsageWindow `json:"window"`
	Metrics  []MetricAgg `json:"metrics"`
	TotalQty int64       `json:"total_qty"`
}

// usageAggregateSQL is byte-identical to metering.aggregateSQL: $1 tenant_id is
// ALWAYS bound (defense-in-depth atop RLS); metric/from/to are nullable filters
// over a half-open [from,to) window.
const usageAggregateSQL = `
SELECT metric, COALESCE(SUM(qty), 0)::bigint AS qty, COUNT(*)::bigint AS window_count
  FROM public.tenant_usage
 WHERE tenant_id = $1
   AND ($2::text        IS NULL OR metric       =  $2)
   AND ($3::timestamptz IS NULL OR window_start >= $3)
   AND ($4::timestamptz IS NULL OR window_start <  $4)
 GROUP BY metric
 ORDER BY metric`

// parseTimeParam parses an optional ?from / ?to window bound. Empty = the zero
// time (an unbounded side). A present value is accepted as RFC3339 OR a unix-ms
// integer; anything else is a 400 — mirrors metering.parseWindowBound so the
// /me/usage filter behaves identically to the B1c {id}/usage filter.
func parseTimeParam(w http.ResponseWriter, raw, field string) (time.Time, bool) {
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

// aggregateUsage sums one tenant's public.tenant_usage rows over an optional
// window, replicating the B1c metering Reader's query over the admin pool (the
// Reader has no exported constructor). metric=="" / zero from / zero to disable
// that filter (passed as SQL NULL).
func (s *Service) aggregateUsage(ctx context.Context, tenantID, metric string, from, to time.Time) (UsageResponse, error) {
	resp := UsageResponse{
		TenantID: tenantID,
		Window:   UsageWindow{From: rfc3339OrEmpty(from), To: rfc3339OrEmpty(to)},
		Metrics:  make([]MetricAgg, 0),
	}
	rows, err := s.db.AdminQuery(ctx, usageAggregateSQL,
		tenantID, shared.NullableStr(metric), shared.NullableTime(from), shared.NullableTime(to))
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
	return resp, rows.Err()
}

// updateBillingPlan reflects a plan change into public.tenant_billing.plan when
// BILLING_ENABLED. Best-effort sync of the local tenant->plan map — it does NOT
// touch Stripe (the live subscription swap is the separate B4b step). Idempotent
// UPSERT keyed by tenant_id; a missing row (tenant never billed) is created so
// the plan column is consistent for when billing is later configured.
func (s *Service) updateBillingPlan(ctx context.Context, tenantID, plan string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.tenant_billing (tenant_id, plan, updated_at)
		VALUES ($1, $2, now())
		ON CONFLICT (tenant_id)
		DO UPDATE SET plan = EXCLUDED.plan, updated_at = now()`,
		tenantID, plan)
}

// rfc3339OrEmpty renders a bound for the echoed window ("" when unbounded).
func rfc3339OrEmpty(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}
