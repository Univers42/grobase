package metering

import (
	"context"
	"fmt"
	"time"
)

// unreportedSQL selects usage windows in the current period that have a Stripe
// customer (tenant_billing) and a billable metric and have NOT yet been reported
// (no billing_reported row). $1 = window-start floor (previous-period start −
// lookback, see billingFloor); $2 = the billable metrics (text[]). Read as the
// privileged control-plane role
// (BYPASSRLS) — it must see every tenant's rows to bill globally, exactly like the
// B1c read API and the QuotaGuard (RLS-scoping here would be a category error).
const unreportedSQL = `
SELECT u.idempotency_key, u.tenant_id, u.metric, u.qty,
       EXTRACT(EPOCH FROM u.window_start)::bigint AS window_unix,
       b.stripe_customer_id
  FROM public.tenant_usage u
  JOIN public.tenant_billing b ON b.tenant_id = u.tenant_id
  LEFT JOIN public.billing_reported r ON r.idempotency_key = u.idempotency_key
 WHERE u.window_start >= $1
   AND u.metric = ANY($2)
   AND b.stripe_customer_id <> ''
   AND r.idempotency_key IS NULL`

// markReportedSQL records a window as sent so it is never re-POSTed.
const markReportedSQL = `
INSERT INTO public.billing_reported (idempotency_key, tenant_id, metric, qty, reported_at)
VALUES ($1, $2, $3, $4, now())
ON CONFLICT (idempotency_key) DO NOTHING`

// report queries the un-reported windows and flushes them to Stripe.
func (r *BillingReporter) report(ctx context.Context) error {
	floor := r.billingFloor(time.Now().UTC())
	rows, err := r.db.AdminQuery(ctx, unreportedSQL, floor, r.catalog.metrics())
	if err != nil {
		return fmt.Errorf("billing-reporter: query usage: %w", err)
	}
	var todo []usageRow
	for rows.Next() {
		var u usageRow
		if err := rows.Scan(&u.idem, &u.tenant, &u.metric, &u.qty, &u.windowUnix, &u.customer); err != nil {
			rows.Close()
			return fmt.Errorf("billing-reporter: scan: %w", err)
		}
		todo = append(todo, u)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("billing-reporter: rows: %w", err)
	}
	return r.flush(ctx, todo)
}

// flush POSTs each window as a Stripe meter event and marks it reported. A window
// whose metric is not in the catalog is skipped (defense — the SQL already filters
// by ANY($metrics)). A POST failure leaves the window UN-marked (retried next
// tick; Stripe dedups on identifier so a retry after a partial success is safe).
// A mark failure does NOT abort the rest of the batch — the window is left
// un-marked (retried; Stripe dedup absorbs the re-POST) and we keep going, then
// return an aggregated error so the failure is visible without stranding the other
// windows. Split out from report() so the metric→event mapping + idempotency are
// unit-testable over fakes (no pgx.Rows).
func (r *BillingReporter) flush(ctx context.Context, rows []usageRow) error {
	reported, markFails := 0, 0
	var firstMarkErr error
	for _, u := range rows {
		marked, err := r.sendWindow(ctx, u)
		if err != nil {
			markFails++
			if firstMarkErr == nil {
				firstMarkErr = err
			}
			continue
		}
		if marked {
			reported++
		}
	}
	if reported > 0 {
		r.log.Info("billing reported usage windows to Stripe", "count", reported)
	}
	if firstMarkErr != nil {
		return fmt.Errorf("billing-reporter: %d ledger mark(s) failed: %w", markFails, firstMarkErr)
	}
	return nil
}

// sendWindow POSTs one window's meter event and records it in the ledger. It
// returns (marked, markErr): a non-billable metric or a failed POST is (false,
// nil) — skipped, the window left un-marked for next tick (Stripe dedups the
// re-POST); a successful POST whose ledger mark failed is (false, err) so flush
// can aggregate it without stranding the rest of the batch.
func (r *BillingReporter) sendWindow(ctx context.Context, u usageRow) (bool, error) {
	eventName, ok := r.catalog.eventName(u.metric)
	if !ok {
		return false, nil
	}
	var ts int64
	if r.sendTimestamp {
		ts = u.windowUnix
	}
	if err := r.biller.ReportMeterEvent(ctx, MeterEvent{
		EventName: eventName, CustomerID: u.customer, Value: u.qty, Identifier: u.idem, Timestamp: ts,
	}); err != nil {
		r.log.Warn("billing: meter event failed (will retry)", "tenant", u.tenant, "metric", u.metric, "err", err)
		return false, nil
	}
	if err := r.db.AdminExec(ctx, markReportedSQL, u.idem, u.tenant, u.metric, u.qty); err != nil {
		r.log.Warn("billing: ledger mark failed (window will re-POST next tick; Stripe dedups)", "tenant", u.tenant, "metric", u.metric, "err", err)
		return false, err
	}
	return true, nil
}

// billingFloor is the lower bound for the usage-window scan. It is ONLY a
// performance bound — the LEFT JOIN against billing_reported (r.idempotency_key IS
// NULL) is what prevents a double-bill, so widening the floor can never over-bill.
// It defaults to the start of the PREVIOUS period (minus the optional lookback),
// not the current one, so a window in the previous period's last interval that was
// never reported before the clock rolled over (reporter down at the boundary, or a
// late-ingested window) is still picked up and billed — closing the month-boundary
// revenue-loss edge. A multi-period outage needs a larger BILLING_REPORT_LOOKBACK_MS.
func (r *BillingReporter) billingFloor(now time.Time) time.Time {
	cur := periodStartFor(r.period, now)
	prev := periodStartFor(r.period, cur.Add(-time.Nanosecond))
	return prev.Add(-r.lookback)
}
