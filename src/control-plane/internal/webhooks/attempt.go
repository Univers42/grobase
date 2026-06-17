package webhooks

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

// handleEvent inserts pending delivery rows for every matching subscription,
// then triggers an immediate first attempt for each one.
func (d *Dispatcher) handleEvent(ctx context.Context, aggregate string, msg redis.XMessage) error {
	eventID, _ := msg.Values["id"].(string)
	eventType, _ := msg.Values["event_type"].(string)
	aggregateID, _ := msg.Values["aggregate_id"].(string)
	payloadStr, _ := msg.Values["payload"].(string)
	if eventID == "" || eventType == "" {
		return nil
	}

	// Outbox events are tenant-attributed via payload (tenant_id field) when
	// present; otherwise the event is broadcast to subscribers across all
	// tenants of the same aggregate. The dispatcher only delivers to subs
	// matching the event's tenant_id.
	var payload map[string]any
	if payloadStr != "" {
		_ = json.Unmarshal([]byte(payloadStr), &payload)
	}
	tenantID := stringFromPayload(payload, "tenant_id")

	subs, err := d.lookupMatching(ctx, tenantID, aggregate, eventType)
	if err != nil {
		return fmt.Errorf("lookup subscriptions: %w", err)
	}

	for _, sub := range subs {
		if err := d.enqueueDelivery(ctx, sub, eventID, aggregate, aggregateID, eventType, payload); err != nil {
			d.log.Warn("enqueue delivery failed", "sub", sub.ID, "event", eventID, "err", err)
			continue
		}
		go d.attempt(context.Background(), sub.ID, eventID)
	}
	return nil
}

// lookupMatching reads the active subscription set for the tenant and filters
// the event-type/aggregate match in-Go. For modest sub counts (<10k/tenant)
// in-Go matching on the TEXT[] columns is cheaper than a SQL array filter.
//
// The `tenant_id = $1` predicate is the AUTHORITATIVE tenant scope and is NOT
// optional: this dispatcher connects to the system Postgres as the table-owning
// `postgres` superuser, so the per-tenant RLS policy on webhook_subscriptions
// is silently bypassed (owner + ENABLE-not-FORCE). Without it, a write in one
// tenant would POST that tenant's row payload to EVERY tenant's webhook URL —
// a cross-tenant data-exfiltration breach. We scope explicitly in SQL.
func (d *Dispatcher) lookupMatching(ctx context.Context, tenantID, aggregate, eventType string) ([]Subscription, error) {
	if tenantID == "" {
		return nil, nil
	}
	subs := make([]Subscription, 0)
	err := d.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, tenant_id, name, url, event_types, aggregates,
			       active, headers::text, max_attempts, timeout_ms,
			       created_at::text, updated_at::text
			  FROM public.webhook_subscriptions
			 WHERE active = true AND tenant_id = $1`, tenantID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var sub Subscription
			if err := scanSubscription(rows, &sub); err != nil {
				return err
			}
			if sub.matches(aggregate, eventType) {
				subs = append(subs, sub)
			}
		}
		return rows.Err()
	})
	return subs, err
}

func (d *Dispatcher) enqueueDelivery(
	ctx context.Context,
	sub Subscription,
	eventID, aggregate, _, eventType string,
	payload map[string]any,
) error {
	body, _ := json.Marshal(payload)
	return d.db.TenantTx(ctx, sub.TenantID, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			INSERT INTO public.webhook_deliveries
			       (subscription_id, tenant_id, event_id, aggregate, event_type, payload, next_attempt_at)
			VALUES ($1::uuid, $2, $3, $4, $5, $6::jsonb, now())
			ON CONFLICT (subscription_id, event_id) DO NOTHING`,
			sub.ID, sub.TenantID, eventID, aggregate, eventType, string(body))
		return err
	})
}

// attempt performs one HTTP delivery attempt and updates the ledger row.
//
// Reads from the admin pool (RLS-bypass) because retries can fire from a
// background scan that has no tenant context; the join is keyed by the
// subscription_id UUID + event_id pair which is unique under tenant scope.
func (d *Dispatcher) attempt(ctx context.Context, subscriptionID, eventID string) {
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
		return
	}
	defer rows.Close()
	if !rows.Next() {
		return
	}

	var (
		sub         Subscription
		bodyStr     string
		attempts    int
		secret      string
		headersJSON string
	)
	if err := rows.Scan(&sub.ID, &sub.TenantID, &sub.Name, &sub.URL,
		&sub.EventTypes, &sub.Aggregates, &sub.Active, &headersJSON,
		&sub.MaxAttempts, &sub.TimeoutMs, &sub.CreatedAt, &sub.UpdatedAt,
		&bodyStr, &attempts, &secret); err != nil {
		d.log.Warn("attempt scan failed", "err", err)
		return
	}
	sub.Headers = map[string]string{}
	if headersJSON != "" {
		_ = json.Unmarshal([]byte(headersJSON), &sub.Headers)
	}

	statusCode, attemptErr := d.deliver(ctx, sub, secret, eventID, bodyStr)
	d.recordAttempt(ctx, subscriptionID, eventID, attempts+1, sub.MaxAttempts, statusCode, attemptErr)
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

	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, sub.URL, bytes.NewBufferString(body))
	if err != nil {
		return 0, err
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

// deliveryOutcomeHelp documents the baas_webhook_deliveries_total counter:
// every delivery attempt resolves to exactly one outcome label.
const deliveryOutcomeHelp = "Webhook delivery attempts by terminal outcome (success|retry|dead)"

func (d *Dispatcher) recordAttempt(ctx context.Context,
	subscriptionID, eventID string, attempts, maxAttempts, statusCode int, attemptErr error) {
	if attemptErr == nil {
		_ = d.db.AdminExec(ctx, `
			UPDATE public.webhook_deliveries
			   SET status = 'success', attempts = $3, last_status_code = $4,
			       last_error = NULL, delivered_at = now()
			 WHERE subscription_id = $1::uuid AND event_id = $2`,
			subscriptionID, eventID, attempts, statusCode)
		shared.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "success")
		return
	}
	errMsg := attemptErr.Error()
	if attempts >= maxAttempts {
		_ = d.db.AdminExec(ctx, `
			UPDATE public.webhook_deliveries
			   SET status = 'dead', attempts = $3, last_status_code = $4,
			       last_error = $5
			 WHERE subscription_id = $1::uuid AND event_id = $2`,
			subscriptionID, eventID, attempts, nullInt(statusCode), errMsg)
		shared.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "dead")
		d.log.Warn("delivery moved to DLQ", "sub", subscriptionID, "event", eventID, "attempts", attempts)
		return
	}
	shared.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "retry")
	next := time.Now().Add(backoff(attempts))
	_ = d.db.AdminExec(ctx, `
		UPDATE public.webhook_deliveries
		   SET status = 'pending', attempts = $3, last_status_code = $4,
		       last_error = $5, next_attempt_at = $6
		 WHERE subscription_id = $1::uuid AND event_id = $2`,
		subscriptionID, eventID, attempts, nullInt(statusCode), errMsg, next)
}
