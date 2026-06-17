package telemetryexport

import (
	"context"
	"fmt"
	"time"
)

// target is one tenant's export configuration row (public.tenant_telemetry_targets).
type target struct {
	tenantID   string
	endpoint   string
	authHeader string // "" → no Authorization header
	format     string // "otlp" | "ndjson"
	cursor     time.Time
}

// usageRow is one B1 metering aggregate row (public.tenant_usage) for a tenant.
type usageRow struct {
	metric      string
	windowStart time.Time
	qty         int64
}

// listTargetsSQL returns every opted-in + ENABLED export target. A tenant with no
// row, or enabled=false, is excluded — so it is never exported (the safe default).
// The exporter reads as the privileged control-plane role (BYPASSRLS), exactly like
// the metering consumer / QuotaGuard / spend-cap guard: it must see every opted-in
// tenant to forward globally. Per-tenant isolation is enforced downstream by
// scoping each usage scan to ONE tenant_id and sending only to that tenant's row's
// own endpoint.
const listTargetsSQL = `
SELECT tenant_id, endpoint, COALESCE(auth_header, ''), format, last_cursor
  FROM public.tenant_telemetry_targets
 WHERE enabled = TRUE
 ORDER BY tenant_id`

// tenantUsageSinceSQL reads ONE tenant's usage windows strictly newer than its
// cursor. $1 = tenant_id (the per-tenant scope — the load-bearing isolation), $2 =
// cursor (exclusive high-water mark), $3 = row cap. ORDER BY window_start so the
// new cursor is the max shipped window and the next tick resumes exactly after it.
const tenantUsageSinceSQL = `
SELECT metric, window_start, qty
  FROM public.tenant_usage
 WHERE tenant_id = $1
   AND window_start > $2
 ORDER BY window_start
 LIMIT $3`

// advanceCursorSQL moves a tenant's high-water mark to the max window it has shipped
// so the same window is never re-exported. $1 = tenant_id, $2 = new cursor.
const advanceCursorSQL = `
UPDATE public.tenant_telemetry_targets
   SET last_cursor = $2, updated_at = now()
 WHERE tenant_id = $1`

// exportOnce runs one full sweep: list the enabled targets, then for EACH tenant
// forward only that tenant's new usage to only that tenant's endpoint. One tenant's
// failure is isolated (logged, cursor unadvanced, retried) and never aborts the
// sweep. Returns the count of tenants that exported at least one row (used by the
// initial-sweep log line + tests). On a per-tenant failure tenant_id is emitted as a
// structured log FIELD (cardinality-safe, the B5 convention — never a Prometheus label).
func (e *Exporter) exportOnce(ctx context.Context) int {
	targets, err := e.listTargets(ctx)
	if err != nil {
		e.log.Warn("telemetry export: list targets failed", "err", err)
		return 0
	}
	exported := 0
	for _, t := range targets {
		n, err := e.exportTenant(ctx, t)
		if err != nil {
			e.log.Warn("telemetry export: tenant export failed (cursor unadvanced, retried next tick)",
				"tenant_id", t.tenantID, "err", err)
			continue
		}
		if n > 0 {
			exported++
		}
	}
	return exported
}

// exportTenant forwards ONE tenant's new usage to ITS endpoint. It (1) reads only
// rows for t.tenantID newer than t.cursor, (2) builds a batch tagged with t.tenantID,
// (3) delivers it to ONLY t.endpoint, (4) advances t's cursor to the max shipped
// window (rows are window-ordered, so the newest is the last). If there is nothing
// new it is a no-op (no delivery, no cursor write). The per-tenant query scope + the
// per-tenant endpoint together make a cross-tenant export impossible by construction.
// If delivery succeeds but the cursor write fails, the failure is logged and the same
// window re-ships next tick (at-least-once; a collector dedups on resource + timestamp
// — better a duplicate than silent loss).
func (e *Exporter) exportTenant(ctx context.Context, t target) (int, error) {
	rows, err := e.tenantUsageSince(ctx, t.tenantID, t.cursor)
	if err != nil {
		return 0, fmt.Errorf("read usage: %w", err)
	}
	if len(rows) == 0 {
		return 0, nil
	}
	body, contentType := e.buildBatch(t, rows)
	if err := e.sink.Deliver(ctx, t.endpoint, t.authHeader, contentType, body); err != nil {
		return 0, fmt.Errorf("deliver to %s: %w", t.endpoint, err)
	}
	newCursor := rows[len(rows)-1].windowStart
	if err := e.db.AdminExec(ctx, advanceCursorSQL, t.tenantID, newCursor); err != nil {
		e.log.Warn("telemetry export: cursor advance failed (window may re-ship)",
			"tenant_id", t.tenantID, "err", err)
	}
	e.log.Debug("telemetry export: forwarded tenant batch",
		"tenant_id", t.tenantID, "rows", len(rows), "format", t.format)
	return len(rows), nil
}

// listTargets loads every enabled export target.
func (e *Exporter) listTargets(ctx context.Context) ([]target, error) {
	rows, err := e.db.AdminQuery(ctx, listTargetsSQL)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []target
	for rows.Next() {
		var t target
		if err := rows.Scan(&t.tenantID, &t.endpoint, &t.authHeader, &t.format, &t.cursor); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// tenantUsageSince reads one tenant's usage rows newer than cursor (capped).
func (e *Exporter) tenantUsageSince(ctx context.Context, tenantID string, cursor time.Time) ([]usageRow, error) {
	rows, err := e.db.AdminQuery(ctx, tenantUsageSinceSQL, tenantID, cursor, e.batchRows)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []usageRow
	for rows.Next() {
		var u usageRow
		if err := rows.Scan(&u.metric, &u.windowStart, &u.qty); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}
