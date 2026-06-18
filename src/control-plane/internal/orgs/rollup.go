package orgs

import "context"

// rollup.go — D1.5: per-org billing rollup READ. Reads the read-only
// public.org_usage_rollup view (migration 044), which SUMs the per-project
// public.tenant_usage rows (040, the SINGLE source of usage truth) for every
// project where tenants.org_id = this org. Per-project qty is PRESERVED; the
// rollup is a pure aggregation that never mutates a usage row, so B1 metering
// parity is untouched.
//
// This is a READ over a view. The live Stripe push is explicitly OUT OF SCOPE for
// D1 (it is B7.4/B7.5 / D4.9, which carry their own Stripe human-atom); D1.5 only
// surfaces the local aggregation.

// MetricRollup is one metric's summed usage across an org's projects.
type MetricRollup struct {
	Metric      string `json:"metric"`
	Qty         int64  `json:"qty"`
	WindowCount int64  `json:"window_count"`
}

// OrgUsage is the per-org usage rollup response.
type OrgUsage struct {
	OrgID    string         `json:"org_id"`
	Metrics  []MetricRollup `json:"metrics"`
	TotalQty int64          `json:"total_qty"`
}

// OrgUsageRollup aggregates the org's per-project usage via the org_usage_rollup
// view. org_id is ALWAYS bound (defense-in-depth atop the RLS policy on the
// underlying tables). An org with no metered projects returns empty metrics.
func (s *Service) OrgUsageRollup(ctx context.Context, orgID string) (OrgUsage, error) {
	resp := OrgUsage{OrgID: orgID, Metrics: make([]MetricRollup, 0)}
	rows, err := s.db.AdminQuery(ctx, `
		SELECT metric, qty, window_count
		  FROM public.org_usage_rollup
		 WHERE org_id::text = $1
		 ORDER BY metric`, orgID)
	if err != nil {
		return resp, err
	}
	defer rows.Close()
	for rows.Next() {
		var m MetricRollup
		if err := rows.Scan(&m.Metric, &m.Qty, &m.WindowCount); err != nil {
			return resp, err
		}
		resp.Metrics = append(resp.Metrics, m)
		resp.TotalQty += m.Qty
	}
	return resp, rows.Err()
}
