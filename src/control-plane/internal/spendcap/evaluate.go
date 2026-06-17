package spendcap

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// rateTable maps a B1 usage metric → its price in MILLI-cents per unit
// (cents×1000), so a fractional per-unit price (e.g. 0.002¢ / query) is an
// integer and money math never touches float. Spend in cents = Σ(qty × milliRate)
// / 1000. Loaded from env SPEND_RATE_<METRIC> (a decimal cents-per-unit string,
// e.g. "0.0001"), so $-pricing is per-deployment, never in packages.json.
type rateTable struct {
	milliPerUnit map[string]int64 // metric → milli-cents per unit
}

// billableMetricEnv is the closed set of priceable dimensions and the env var that
// carries each one's cents-per-unit rate. Mirrors metering.billableMetricEnv so the
// spend model uses B1's frozen metric vocabulary (store.go fieldMetric) — extending
// to a new dimension is one line here plus the env in the deployment.
var billableMetricEnv = map[string]string{
	"query.count":          "SPEND_RATE_QUERY_COUNT",
	"query.rows":           "SPEND_RATE_QUERY_ROWS",
	"write.rows":           "SPEND_RATE_WRITE_ROWS",
	"storage.bytes":        "SPEND_RATE_STORAGE_BYTES",
	"realtime.minutes":     "SPEND_RATE_REALTIME_MINUTES",
	"function.invocations": "SPEND_RATE_FUNCTION_INVOCATIONS",
}

// loadRateTable reads the SPEND_RATE_* env into a metric→milli-cents map. Only
// metrics with a positive rate are included (opt-in per dimension); an unparsable
// or non-positive rate is skipped (it would price that dimension at zero anyway).
func loadRateTable() rateTable {
	m := make(map[string]int64, len(billableMetricEnv))
	for metric, ev := range billableMetricEnv {
		raw := strings.TrimSpace(shared.EnvStr(ev, ""))
		if raw == "" {
			continue
		}
		// cents-per-unit decimal → milli-cents integer (×1000), rounded.
		if cents, ok := parseCentsToMilli(raw); ok && cents > 0 {
			m[metric] = cents
		}
	}
	return rateTable{milliPerUnit: m}
}

// parseCentsToMilli converts a decimal cents string ("0.0001") to milli-cents
// (cents×1000) as an integer, rounding to the nearest milli-cent. Returns false on
// a malformed value so a typo cannot silently price a dimension wrong.
func parseCentsToMilli(s string) (int64, bool) {
	var f float64
	if _, err := fmt.Sscanf(s, "%g", &f); err != nil || f < 0 {
		return 0, false
	}
	// +0.5 for round-to-nearest on the positive domain.
	return int64(f*1000 + 0.5), true
}

func (t rateTable) empty() bool { return len(t.milliPerUnit) == 0 }

// metrics returns the priced metric names, sorted for a stable `= ANY($1)` SQL
// argument and deterministic logging.
func (t rateTable) metrics() []string {
	out := make([]string, 0, len(t.milliPerUnit))
	for k := range t.milliPerUnit {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// spendCentsFor converts a per-metric usage map to spend in whole cents using the
// rate table. Integer math throughout: Σ(qty × milliRate) accumulated in
// milli-cents, divided by 1000 at the end. A metric with no rate contributes 0.
func (t rateTable) spendCentsFor(usageByMetric map[string]int64) int64 {
	var milli int64
	for metric, qty := range usageByMetric {
		if r, ok := t.milliPerUnit[metric]; ok && qty > 0 {
			milli += qty * r
		}
	}
	return milli / 1000
}

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
// SQL scan we floor on the common current-period start ($2). Tenants on a shorter
// period (hour/day) than the scan floor (we floor on the LONGEST configured period,
// month) only ever over-count toward their cap by including older windows — which
// is conservative for a HARD cap (fail toward protecting the budget). A future
// per-period scan would split this; for the MVP a single month-floor scan is the
// safe, simple choice and is documented here so the trade-off is explicit.
func (g *Guard) evaluate(ctx context.Context) error {
	now := time.Now().UTC()
	floor := periodStartFor("month", now) // widest period = month → conservative for hard caps
	rows, err := g.db.AdminQuery(ctx, spendUsageSQL, g.rates.metrics(), floor)
	if err != nil {
		return fmt.Errorf("spend-cap: query usage: %w", err)
	}
	byTenant := map[string]*tenantSpend{}
	for rows.Next() {
		var tid, period, metric string
		var budget, qty int64
		var alertFired bool
		if err := rows.Scan(&tid, &period, &budget, &alertFired, &metric, &qty); err != nil {
			rows.Close()
			return fmt.Errorf("spend-cap: scan: %w", err)
		}
		ts, ok := byTenant[tid]
		if !ok {
			ts = &tenantSpend{tenantID: tid, period: period, budgetCents: budget, alertFired: alertFired, usageByMetric: map[string]int64{}}
			byTenant[tid] = ts
		}
		ts.usageByMetric[metric] += qty
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("spend-cap: rows: %w", err)
	}

	over := make([]string, 0)
	for _, ts := range byTenant {
		if ts.budgetCents <= 0 {
			continue // 0 = unlimited → never over, never alert (safe default)
		}
		spent := g.rates.spendCentsFor(ts.usageByMetric)
		if spent >= ts.budgetCents {
			over = append(over, ts.tenantID)
		}
		g.maybeAlert(ctx, ts, spent, now)
	}
	return g.publish(ctx, over)
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
	default: // "month"
		return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	}
}
