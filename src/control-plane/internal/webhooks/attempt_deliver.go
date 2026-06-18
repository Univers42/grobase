package webhooks

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// pendingDelivery is the scanned view of one pending webhook_deliveries row
// joined to its subscription.
type pendingDelivery struct {
	sub      Subscription
	body     string
	secret   string
	attempts int
}

// attempt performs one HTTP delivery attempt and updates the ledger row.
//
// Reads from the admin pool (RLS-bypass) because retries can fire from a
// background scan that has no tenant context; the join is keyed by the
// subscription_id UUID + event_id pair which is unique under tenant scope.
func (d *Dispatcher) attempt(ctx context.Context, subscriptionID, eventID string) {
	p, ok := d.loadPending(ctx, subscriptionID, eventID)
	if !ok {
		return
	}
	statusCode, attemptErr := d.deliver(ctx, p.sub, p.secret, eventID, p.body)
	o := attemptOutcome{subscriptionID, eventID, p.attempts + 1, statusCode}
	d.recordAttempt(ctx, o, p.sub.MaxAttempts, attemptErr)
}

// loadPending fetches the single pending delivery row; ok is false when the row
// is absent (already delivered/dead) or a load/scan error was logged.
func (d *Dispatcher) loadPending(ctx context.Context, subscriptionID, eventID string) (pendingDelivery, bool) {
	const q = `
		SELECT s.id::text, s.tenant_id, s.name, s.url, s.event_types, s.aggregates,
		       s.active, s.headers::text, s.max_attempts, s.timeout_ms,
		       s.created_at::text, s.updated_at::text,
		       d.payload::text, d.attempts, s.secret
		  FROM public.webhook_deliveries d
		  JOIN public.webhook_subscriptions s ON s.id = d.subscription_id
		 WHERE d.subscription_id = $1::uuid AND d.event_id = $2
		   AND d.status = 'pending'`
	rows, err := d.db.AdminQuery(ctx, q, subscriptionID, eventID)
	if err != nil {
		d.log.Warn("attempt load failed", "sub", subscriptionID, "event", eventID, "err", err)
		return pendingDelivery{}, false
	}
	defer rows.Close()
	if !rows.Next() {
		return pendingDelivery{}, false
	}
	var p pendingDelivery
	if err := scanAttemptRow(rows, &p); err != nil {
		d.log.Warn("attempt scan failed", "err", err)
		return pendingDelivery{}, false
	}
	return p, true
}

func scanAttemptRow(row scannable, p *pendingDelivery) error {
	var headersJSON string
	sub := &p.sub
	if err := row.Scan(&sub.ID, &sub.TenantID, &sub.Name, &sub.URL,
		&sub.EventTypes, &sub.Aggregates, &sub.Active, &headersJSON,
		&sub.MaxAttempts, &sub.TimeoutMs, &sub.CreatedAt, &sub.UpdatedAt,
		&p.body, &p.attempts, &p.secret); err != nil {
		return err
	}
	sub.Headers = map[string]string{}
	if headersJSON != "" {
		_ = json.Unmarshal([]byte(headersJSON), &sub.Headers)
	}
	return nil
}

// deliver POSTs the payload with the HMAC signature header. The body is the
// raw event payload JSON; the signature is computed over the body.
func (d *Dispatcher) deliver(ctx context.Context, sub Subscription, secret, eventID, body string) (int, error) {
	timeout := time.Duration(sub.TimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	req, err := buildDeliveryRequest(reqCtx, sub, secret, eventID, body)
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

func buildDeliveryRequest(ctx context.Context, sub Subscription, secret, eventID, body string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.URL, bytes.NewBufferString(body))
	if err != nil {
		return nil, err
	}
	sig := sign(secret, body)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Baas-Event-Id", eventID)
	req.Header.Set("X-Baas-Subscription-Id", sub.ID)
	req.Header.Set("X-Baas-Signature", "sha256="+sig)
	req.Header.Set("User-Agent", "mini-baas-webhooks/1.0")
	for k, v := range sub.Headers {
		req.Header.Set(k, v)
	}
	return req, nil
}
