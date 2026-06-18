package spendcap

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// tenantSpend is one tenant's accumulated period state during an evaluation.
type tenantSpend struct {
	tenantID      string
	period        string
	budgetCents   int64
	alertFired    bool // already fired the alert for THIS period
	usageByMetric map[string]int64
}

// spendUsageSQL joins per-tenant period usage to its budget. Only tenants WITH a
// tenant_budgets row are returned — a tenant without a budget has no cap and must
// not be halted, so excluding it from the scan is the safe default (and keeps the
// scan small: only opted-in tenants). $1 = the priced metrics (text[]); $2 = the
// current period-start floor.
//
// The guard reads as the privileged control-plane role (BYPASSRLS), exactly like
// the B1c read-API, the ingest consumer, and the QuotaGuard — it must see EVERY
// opted-in tenant's rows to enforce globally (RLS-scoping here would be a category
// error; the per-tenant isolation guarantee is for tenant-facing reads).
const spendUsageSQL = `
SELECT b.tenant_id,
       b.period,
       b.budget_cents,
       (b.alert_fired_period IS NOT NULL AND b.alert_fired_period >= $2) AS alert_fired,
       u.metric,
       COALESCE(SUM(u.qty), 0)::bigint AS qty
  FROM public.tenant_budgets b
  JOIN public.tenant_usage   u ON u.tenant_id = b.tenant_id
 WHERE u.metric = ANY($1)
   AND u.window_start >= $2
 GROUP BY b.tenant_id, b.period, b.budget_cents, alert_fired, u.metric`

// markAlertSQL stamps the once-per-period alert so it never re-fires this period.
const markAlertSQL = `
UPDATE public.tenant_budgets
   SET alert_fired_period = $2, updated_at = now()
 WHERE tenant_id = $1`

// evaluate recomputes the over-budget set, publishes it atomically, and fires any
// due 80% alerts. periodStart is the current period floor; because a tenant may set
// its own period, we compute spend per row against its OWN period — but to keep ONE
// SQL scan we floor on the common current-period start ($2), the widest (month)
// period so the scan stays conservative for hard caps. Tenants on a shorter
// period (hour/day) than the scan floor (we floor on the LONGEST configured period,
// month) only ever over-count toward their cap by including older windows — which
// is conservative for a HARD cap (fail toward protecting the budget). A future
// per-period scan would split this; for the MVP a single month-floor scan is the
// safe, simple choice and is documented here so the trade-off is explicit. A budget
// of 0 means unlimited (no cap) — such a tenant is never over and never alerts (the
// safe default).
func (g *Guard) evaluate(ctx context.Context) error {
	now := time.Now().UTC()
	floor := periodStartFor("month", now)
	rows, err := g.db.AdminQuery(ctx, spendUsageSQL, g.rates.metrics(), floor)
	if err != nil {
		return fmt.Errorf("spend-cap: query usage: %w", err)
	}
	byTenant, err := g.scanSpend(rows)
	if err != nil {
		return err
	}
	over := make([]string, 0)
	for _, ts := range byTenant {
		if ts.budgetCents <= 0 {
			continue
		}
		spent := g.rates.spendCentsFor(ts.usageByMetric)
		if spent >= ts.budgetCents {
			over = append(over, ts.tenantID)
		}
		g.maybeAlert(ctx, ts, spent, now)
	}
	return g.publish(ctx, over)
}

// scanSpend folds the usage×budget rows into one tenantSpend per tenant, summing
// per-metric qty. It always closes rows; a scan or iteration error is wrapped.
func (g *Guard) scanSpend(rows pgx.Rows) (map[string]*tenantSpend, error) {
	defer rows.Close()
	byTenant := map[string]*tenantSpend{}
	for rows.Next() {
		var tid, period, metric string
		var budget, qty int64
		var alertFired bool
		if err := rows.Scan(&tid, &period, &budget, &alertFired, &metric, &qty); err != nil {
			return nil, fmt.Errorf("spend-cap: scan: %w", err)
		}
		ts, ok := byTenant[tid]
		if !ok {
			ts = &tenantSpend{tenantID: tid, period: period, budgetCents: budget, alertFired: alertFired, usageByMetric: map[string]int64{}}
			byTenant[tid] = ts
		}
		ts.usageByMetric[metric] += qty
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("spend-cap: rows: %w", err)
	}
	return byTenant, nil
}

// maybeAlert fires the once-per-period 80% (configurable) ALERT when spend crosses
// the threshold and the alert has not already fired this period. The mark is
// best-effort: an UPDATE failure logs and lets the alert re-fire next tick rather
// than aborting the evaluation (an extra alert is far better than a missed halt).
func (g *Guard) maybeAlert(ctx context.Context, ts *tenantSpend, spent int64, now time.Time) {
	if ts.alertFired || ts.budgetCents <= 0 {
		return
	}
	threshold := ts.budgetCents * int64(g.alertPct) / 100
	if spent < threshold {
		return
	}
	pct := int(spent * 100 / ts.budgetCents)
	g.alerter.BudgetAlert(ctx, ts.tenantID, spent, ts.budgetCents, pct)
	floor := periodStartFor(ts.period, now)
	if err := g.db.AdminExec(ctx, markAlertSQL, ts.tenantID, floor); err != nil {
		g.log.Warn("spend-cap: mark alert-fired failed (alert may re-fire next tick)", "tenant", ts.tenantID, "err", err)
		return
	}
	ts.alertFired = true
}

// publish replaces the over-budget set atomically: clear staging, add members,
// RENAME staging→live (so a reader never sees a partial set), then PEXPIRE so a
// crashed guard cannot leave a stale set halting forever. An EMPTY over set means
// "no tenant is over budget" — we DELETE the live key so the data plane's SMEMBERS
// returns empty (fail-OPEN: no halt). Byte-for-byte the same atomic-publish shape
// as quotaguard.publish.
func (g *Guard) publish(ctx context.Context, over []string) error {
	pipe := g.rdb.TxPipeline()
	pipe.Del(ctx, spendOverStaging)
	if len(over) == 0 {
		pipe.Del(ctx, spendOverSet)
		if _, err := pipe.Exec(ctx); err != nil {
			return fmt.Errorf("spend-cap: publish empty set: %w", err)
		}
		g.log.Debug("spend-cap published over-budget set", "count", 0)
		return nil
	}
	members := make([]any, len(over))
	for i, m := range over {
		members[i] = m
	}
	pipe.SAdd(ctx, spendOverStaging, members...)
	pipe.PExpire(ctx, spendOverStaging, 3*g.interval)
	pipe.Rename(ctx, spendOverStaging, spendOverSet)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("spend-cap: publish set: %w", err)
	}
	g.log.Debug("spend-cap published over-budget set", "count", len(over))
	return nil
}

// periodStartFor returns the inclusive start of the current period for `now`.
// "hour"/"day"/"month" supported; an unknown period falls back to "month" (the
// default) so a typo can never silently widen the window to "all time". Mirrors
// metering.periodStartFor (kept local so spendcap has no metering import cycle).
func periodStartFor(period string, now time.Time) time.Time {
	now = now.UTC()
	switch period {
	case "hour":
		return time.Date(now.Year(), now.Month(), now.Day(), now.Hour(), 0, 0, 0, time.UTC)
	case "day":
		return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	default:
		return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	}
}
