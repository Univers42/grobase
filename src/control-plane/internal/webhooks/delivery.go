package webhooks

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

// Dispatcher consumes outbox.<aggregate> Redis streams, matches them against
// active subscriptions, and POSTs HMAC-signed payloads to subscriber URLs.
// Failures are retried with exponential backoff and parked in the DLQ after
// max_attempts is exceeded.
type Dispatcher struct {
	db          *shared.Postgres
	rdb         *redis.Client
	log         *slog.Logger
	groupName   string
	consumer    string
	httpClient  *http.Client
	pollPause   time.Duration
	retryPeriod time.Duration
}

// DispatcherConfig wires the dispatcher.
type DispatcherConfig struct {
	RedisURL    string
	GroupName   string
	ConsumerID  string
	PollPause   time.Duration
	RetryPeriod time.Duration
}

// NewDispatcher builds a dispatcher; the caller owns the lifecycle.
func NewDispatcher(db *shared.Postgres, log *slog.Logger, cfg DispatcherConfig) (*Dispatcher, error) {
	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		return nil, fmt.Errorf("parse redis url: %w", err)
	}
	if cfg.GroupName == "" {
		cfg.GroupName = "webhook-dispatcher"
	}
	if cfg.ConsumerID == "" {
		cfg.ConsumerID = "webhook-dispatcher-0"
	}
	if cfg.PollPause == 0 {
		cfg.PollPause = 1 * time.Second
	}
	if cfg.RetryPeriod == 0 {
		cfg.RetryPeriod = 5 * time.Second
	}
	return &Dispatcher{
		db:          db,
		rdb:         redis.NewClient(opts),
		log:         log,
		groupName:   cfg.GroupName,
		consumer:    cfg.ConsumerID,
		httpClient:  &http.Client{Timeout: 30 * time.Second},
		pollPause:   cfg.PollPause,
		retryPeriod: cfg.RetryPeriod,
	}, nil
}

// Close releases the redis client.
func (d *Dispatcher) Close() error { return d.rdb.Close() }

// Run blocks until ctx is cancelled. Two concurrent loops: stream consumption
// fans new events into webhook_deliveries; the retry loop re-attempts pending
// deliveries whose next_attempt_at is in the past.
func (d *Dispatcher) Run(ctx context.Context) error {
	go d.retryLoop(ctx)
	return d.consumeLoop(ctx)
}

// consumeLoop discovers the set of outbox.* streams once per tick and runs
// XREADGROUP against them. Newly-created streams are picked up on the next
// tick.
func (d *Dispatcher) consumeLoop(ctx context.Context) error {
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		d.consumeTick(ctx)
	}
}

func (d *Dispatcher) consumeTick(ctx context.Context) {
	streams, err := d.discoverStreams(ctx)
	if err != nil {
		d.log.Warn("stream discovery failed", "err", err)
		d.sleep(ctx, d.pollPause)
		return
	}
	if len(streams) == 0 {
		d.sleep(ctx, d.pollPause)
		return
	}
	for _, s := range streams {
		if err := d.ensureGroup(ctx, s); err != nil {
			d.log.Warn("ensure group failed", "stream", s, "err", err)
		}
	}
	res, err := d.readStreams(ctx, streams)
	if err != nil {
		if !isTransientReadErr(err) {
			d.log.Warn("xreadgroup failed", "err", err)
			d.sleep(ctx, d.pollPause)
		}
		return
	}
	for _, st := range res {
		d.processStream(ctx, st)
	}
}

func (d *Dispatcher) readStreams(ctx context.Context, streams []string) ([]redis.XStream, error) {
	args := make([]string, 0, len(streams)*2)
	args = append(args, streams...)
	for range streams {
		args = append(args, ">")
	}
	return d.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    d.groupName,
		Consumer: d.consumer,
		Streams:  args,
		Count:    32,
		Block:    2 * time.Second,
	}).Result()
}

func (d *Dispatcher) processStream(ctx context.Context, st redis.XStream) {
	aggregate := strings.TrimPrefix(st.Stream, "outbox.")
	for _, msg := range st.Messages {
		if err := d.handleEvent(ctx, aggregate, msg); err != nil {
			d.log.Warn("handle event failed", "stream", st.Stream, "id", msg.ID, "err", err)
			continue
		}
		if err := d.rdb.XAck(ctx, st.Stream, d.groupName, msg.ID).Err(); err != nil {
			d.log.Warn("xack failed", "stream", st.Stream, "id", msg.ID, "err", err)
		}
	}
}

func isTransientReadErr(err error) bool {
	return errors.Is(err, redis.Nil) ||
		errors.Is(err, context.Canceled) ||
		errors.Is(err, context.DeadlineExceeded)
}

// discoverStreams scans Redis keyspace for outbox.* streams.
func (d *Dispatcher) discoverStreams(ctx context.Context) ([]string, error) {
	var (
		cursor uint64
		out    []string
	)
	for {
		keys, next, err := d.rdb.Scan(ctx, cursor, "outbox.*", 256).Result()
		if err != nil {
			return nil, err
		}
		for _, k := range keys {
			t, err := d.rdb.Type(ctx, k).Result()
			if err == nil && t == "stream" {
				out = append(out, k)
			}
		}
		if next == 0 {
			break
		}
		cursor = next
	}
	return out, nil
}

func (d *Dispatcher) ensureGroup(ctx context.Context, stream string) error {
	err := d.rdb.XGroupCreateMkStream(ctx, stream, d.groupName, "0").Err()
	if err == nil {
		return nil
	}
	if strings.Contains(err.Error(), "BUSYGROUP") {
		return nil
	}
	return err
}

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

// retryLoop scans for pending deliveries that have passed their next_attempt_at
// (failed previous attempts) and re-attempts them.
func (d *Dispatcher) retryLoop(ctx context.Context) {
	t := time.NewTicker(d.retryPeriod)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		d.scanAndRetry(ctx)
	}
}

func (d *Dispatcher) scanAndRetry(ctx context.Context) {
	rows, err := d.db.AdminQuery(ctx, `
		SELECT subscription_id::text, event_id
		  FROM public.webhook_deliveries
		 WHERE status = 'pending' AND next_attempt_at <= now() AND attempts > 0
		 ORDER BY next_attempt_at
		 LIMIT 100`)
	if err != nil {
		d.log.Warn("retry scan failed", "err", err)
		return
	}
	type job struct{ subID, eventID string }
	jobs := make([]job, 0)
	for rows.Next() {
		var j job
		if err := rows.Scan(&j.subID, &j.eventID); err != nil {
			continue
		}
		jobs = append(jobs, j)
	}
	rows.Close()
	for _, j := range jobs {
		d.attempt(ctx, j.subID, j.eventID)
	}
}

func sign(secret, body string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(body))
	return hex.EncodeToString(mac.Sum(nil))
}

func stringFromPayload(p map[string]any, key string) string {
	if p == nil {
		return ""
	}
	if v, ok := p[key].(string); ok {
		return v
	}
	return ""
}

func nullInt(n int) any {
	if n == 0 {
		return nil
	}
	return n
}

func (d *Dispatcher) sleep(ctx context.Context, dur time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(dur):
	}
}
