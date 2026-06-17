package functriggers

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// attemptRow is the joined delivery+trigger state one invoke attempt needs.
type attemptRow struct {
	id           string
	tenantID     string
	functionName string
	timeoutMs    int
	maxAttempts  int
	bodyStr      string
	attempts     int
}

// loadAttemptRow reads the pending delivery joined to its trigger from the admin
// pool (RLS-bypass). ok=false means no pending row (already handled or gone).
func (d *Dispatcher) loadAttemptRow(ctx context.Context, triggerID, eventID string) (attemptRow, bool) {
	const q = `
		SELECT t.id::text, t.tenant_id, t.function_name, t.timeout_ms, t.max_attempts,
		       d.payload::text, d.attempts
		  FROM public.function_deliveries d
		  JOIN public.function_triggers t ON t.id = d.trigger_id
		 WHERE d.trigger_id = $1::uuid AND d.event_id = $2
		   AND d.status = 'pending'`
	rows, err := d.db.AdminQuery(ctx, q, triggerID, eventID)
	if err != nil {
		d.log.Warn("attempt load failed", "trigger", triggerID, "event", eventID, "err", err)
		return attemptRow{}, false
	}
	defer rows.Close()
	if !rows.Next() {
		return attemptRow{}, false
	}
	var a attemptRow
	if err := rows.Scan(&a.id, &a.tenantID, &a.functionName, &a.timeoutMs, &a.maxAttempts, &a.bodyStr, &a.attempts); err != nil {
		d.log.Warn("attempt scan failed", "err", err)
		return attemptRow{}, false
	}
	return a, true
}

// attempt performs one function-invoke attempt and updates the ledger row.
// Reads from the admin pool (RLS-bypass) because retries can fire from a
// background scan that has no tenant context.
func (d *Dispatcher) attempt(ctx context.Context, triggerID, eventID string) {
	a, ok := d.loadAttemptRow(ctx, triggerID, eventID)
	if !ok {
		return
	}
	statusCode, attemptErr := d.invoke(ctx, a.tenantID, a.functionName, a.timeoutMs, a.bodyStr)
	d.recordAttempt(ctx, attemptResult{
		triggerID: triggerID, eventID: eventID,
		attempts: a.attempts + 1, maxAttempts: a.maxAttempts, statusCode: statusCode, attemptErr: attemptErr,
	})
}

// invoke POSTs the change payload to functions-runtime
// POST <runtime>/v1/functions/<name>/invoke with the tenant header so the
// runtime resolves the function under the right namespace.
func (d *Dispatcher) invoke(ctx context.Context, tenantID, functionName string, timeoutMs int, body string) (int, error) {
	timeout := time.Duration(timeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	// allow runtime time on top of the function's own budget
	reqCtx, cancel := context.WithTimeout(ctx, timeout+5*time.Second)
	defer cancel()

	req, err := d.buildInvokeRequest(reqCtx, tenantID, functionName, body)
	if err != nil {
		return 0, err
	}
	resp, err := d.httpClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp.StatusCode, nil
	}
	return resp.StatusCode, fmt.Errorf("non-2xx response: %d", resp.StatusCode)
}

// buildInvokeRequest assembles the runtime POST with the tenant + source headers.
func (d *Dispatcher) buildInvokeRequest(ctx context.Context, tenantID, functionName, body string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.invokeURL(functionName), bytes.NewBufferString(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Baas-Tenant-Id", tenantID)
	req.Header.Set("X-Baas-Event-Source", "function-trigger")
	req.Header.Set("User-Agent", "mini-baas-function-triggers/1.0")
	return req, nil
}

// invokeURL builds the runtime invoke URL for a function name. Exported via the
// unexported method so the matching/dispatch logic stays unit-testable.
func (d *Dispatcher) invokeURL(functionName string) string {
	return d.runtimeURL + "/v1/functions/" + functionName + "/invoke"
}
