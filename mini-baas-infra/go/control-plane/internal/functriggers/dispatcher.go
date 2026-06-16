package functriggers

import (
	"bytes"
	"context"
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
// enabled function_triggers, and invokes the target function on the
// functions-runtime. It mirrors webhooks.Dispatcher but with a distinct
// consumer group (so it consumes the same streams independently) and a function
// invoke as the delivery target instead of an external HTTP POST. Failures are
// retried with exponential backoff and parked in the DLQ after max_attempts.
type Dispatcher struct {
	db          *shared.Postgres
	rdb         *redis.Client
	log         *slog.Logger
	groupName   string
	consumer    string
	httpClient  *http.Client
	runtimeURL  string // e.g. http://functions-runtime:3060
	pollPause   time.Duration
	retryPeriod time.Duration
}

// DispatcherConfig wires the function-trigger dispatcher.
type DispatcherConfig struct {
	RedisURL    string
	GroupName   string
	ConsumerID  string
	RuntimeURL  string
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
		cfg.GroupName = "function-dispatcher"
	}
	if cfg.ConsumerID == "" {
		cfg.ConsumerID = "function-dispatcher-0"
	}
	if cfg.RuntimeURL == "" {
		cfg.RuntimeURL = "http://functions-runtime:3060"
	}
	if cfg.PollPause == 0 {
		cfg.PollPause = 1 * time.Second
	}
	if cfg.RetryPeriod == 0 {
		cfg.RetryPeriod = 10 * time.Second
	}
	return &Dispatcher{
		db:          db,
		rdb:         redis.NewClient(opts),
		log:         log,
		groupName:   cfg.GroupName,
		consumer:    cfg.ConsumerID,
		httpClient:  &http.Client{Timeout: 30 * time.Second},
		runtimeURL:  strings.TrimRight(cfg.RuntimeURL, "/"),
		pollPause:   cfg.PollPause,
		retryPeriod: cfg.RetryPeriod,
	}, nil
}

// Close releases the redis client.
func (d *Dispatcher) Close() error { return d.rdb.Close() }

// Run blocks until ctx is cancelled. Stream consumption fans new events into
// function_deliveries; the retry loop re-attempts pending deliveries whose
// next_attempt_at is in the past.
func (d *Dispatcher) Run(ctx context.Context) error {
	go d.retryLoop(ctx)
	return d.consumeLoop(ctx)
}

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

// handleEvent inserts pending delivery rows for every matching trigger, then
// triggers an immediate first invoke for each one.
func (d *Dispatcher) handleEvent(ctx context.Context, aggregate string, msg redis.XMessage) error {
	eventID, _ := msg.Values["id"].(string)
	eventType, _ := msg.Values["event_type"].(string)
	aggregateID, _ := msg.Values["aggregate_id"].(string)
	payloadStr, _ := msg.Values["payload"].(string)
	if eventID == "" || eventType == "" {
		return nil
	}

	var payload map[string]any
	if payloadStr != "" {
		_ = json.Unmarshal([]byte(payloadStr), &payload)
	}
	tenantID := stringFromPayload(payload, "tenant_id")

	triggers, err := d.lookupMatching(ctx, tenantID, aggregate, eventType)
	if err != nil {
		return fmt.Errorf("lookup triggers: %w", err)
	}

	for _, tr := range triggers {
		if err := d.enqueueDelivery(ctx, tr, eventID, aggregate, aggregateID, eventType, payload); err != nil {
			d.log.Warn("enqueue delivery failed", "trigger", tr.ID, "event", eventID, "err", err)
			continue
		}
		go d.attempt(context.Background(), tr.ID, eventID)
	}
	return nil
}

// lookupMatching reads the enabled trigger set for the tenant and filters
// in-Go (same approach as webhooks).
//
// The `tenant_id = $1` predicate is the AUTHORITATIVE tenant scope: this
// dispatcher connects to the system Postgres as the table-owning `postgres`
// superuser, so the per-tenant RLS policy on function_triggers is silently
// bypassed (owner + ENABLE-not-FORCE). Relying on TenantTx's GUC alone would
// return EVERY tenant's enabled triggers and fire them on this event — a
// cross-tenant compute + data-exfiltration breach. We scope explicitly in SQL
// and never depend on RLS being enforced here.
func (d *Dispatcher) lookupMatching(ctx context.Context, tenantID, aggregate, eventType string) ([]Trigger, error) {
	if tenantID == "" {
		return nil, nil
	}
	triggers := make([]Trigger, 0)
	err := d.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, tenant_id, name, function_name, event_types, aggregates,
			       enabled, max_attempts, timeout_ms, created_at::text, updated_at::text
			  FROM public.function_triggers
			 WHERE enabled = true AND tenant_id = $1`, tenantID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var tr Trigger
			if err := scanTrigger(rows, &tr); err != nil {
				return err
			}
			if tr.matches(aggregate, eventType) {
				triggers = append(triggers, tr)
			}
		}
		return rows.Err()
	})
	return triggers, err
}

func (d *Dispatcher) enqueueDelivery(
	ctx context.Context,
	tr Trigger,
	eventID, aggregate, _, eventType string,
	payload map[string]any,
) error {
	body, _ := json.Marshal(payload)
	return d.db.TenantTx(ctx, tr.TenantID, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			INSERT INTO public.function_deliveries
			       (trigger_id, tenant_id, function_name, event_id, aggregate, event_type, payload, next_attempt_at)
			VALUES ($1::uuid, $2, $3, $4, $5, $6, $7::jsonb, now())
			ON CONFLICT (trigger_id, event_id) DO NOTHING`,
			tr.ID, tr.TenantID, tr.FunctionName, eventID, aggregate, eventType, string(body))
		return err
	})
}

// attempt performs one function-invoke attempt and updates the ledger row.
// Reads from the admin pool (RLS-bypass) because retries can fire from a
// background scan that has no tenant context.
func (d *Dispatcher) attempt(ctx context.Context, triggerID, eventID string) {
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
		return
	}
	defer rows.Close()
	if !rows.Next() {
		return
	}

	var (
		id           string
		tenantID     string
		functionName string
		timeoutMs    int
		maxAttempts  int
		bodyStr      string
		attempts     int
	)
	if err := rows.Scan(&id, &tenantID, &functionName, &timeoutMs, &maxAttempts, &bodyStr, &attempts); err != nil {
		d.log.Warn("attempt scan failed", "err", err)
		return
	}
	rows.Close()

	statusCode, attemptErr := d.invoke(ctx, tenantID, functionName, timeoutMs, bodyStr)
	d.recordAttempt(ctx, triggerID, eventID, attempts+1, maxAttempts, statusCode, attemptErr)
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

	url := d.invokeURL(functionName)
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, url, bytes.NewBufferString(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Baas-Tenant-Id", tenantID)
	req.Header.Set("X-Baas-Event-Source", "function-trigger")
	req.Header.Set("User-Agent", "mini-baas-function-triggers/1.0")

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

// invokeURL builds the runtime invoke URL for a function name. Exported via the
// unexported method so the matching/dispatch logic stays unit-testable.
func (d *Dispatcher) invokeURL(functionName string) string {
	return d.runtimeURL + "/v1/functions/" + functionName + "/invoke"
}

func (d *Dispatcher) recordAttempt(ctx context.Context,
	triggerID, eventID string, attempts, maxAttempts, statusCode int, attemptErr error) {
	if attemptErr == nil {
		_ = d.db.AdminExec(ctx, `
			UPDATE public.function_deliveries
			   SET status = 'success', attempts = $3, last_status_code = $4,
			       last_error = NULL, delivered_at = now()
			 WHERE trigger_id = $1::uuid AND event_id = $2`,
			triggerID, eventID, attempts, statusCode)
		return
	}
	errMsg := attemptErr.Error()
	if attempts >= maxAttempts {
		_ = d.db.AdminExec(ctx, `
			UPDATE public.function_deliveries
			   SET status = 'dead', attempts = $3, last_status_code = $4,
			       last_error = $5
			 WHERE trigger_id = $1::uuid AND event_id = $2`,
			triggerID, eventID, attempts, nullInt(statusCode), errMsg)
		d.log.Warn("function delivery moved to DLQ", "trigger", triggerID, "event", eventID, "attempts", attempts)
		return
	}
	next := time.Now().Add(backoff(attempts))
	_ = d.db.AdminExec(ctx, `
		UPDATE public.function_deliveries
		   SET status = 'pending', attempts = $3, last_status_code = $4,
		       last_error = $5, next_attempt_at = $6
		 WHERE trigger_id = $1::uuid AND event_id = $2`,
		triggerID, eventID, attempts, nullInt(statusCode), errMsg, next)
}

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
		SELECT trigger_id::text, event_id
		  FROM public.function_deliveries
		 WHERE status = 'pending' AND next_attempt_at <= now() AND attempts > 0
		 ORDER BY next_attempt_at
		 LIMIT 100`)
	if err != nil {
		d.log.Warn("retry scan failed", "err", err)
		return
	}
	type job struct{ triggerID, eventID string }
	jobs := make([]job, 0)
	for rows.Next() {
		var j job
		if err := rows.Scan(&j.triggerID, &j.eventID); err != nil {
			continue
		}
		jobs = append(jobs, j)
	}
	rows.Close()
	for _, j := range jobs {
		d.attempt(ctx, j.triggerID, j.eventID)
	}
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

// backoff returns the delay before the next attempt using exponential backoff
// capped at 5 minutes (mirrors webhooks).
func backoff(attempt int) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	d := time.Duration(1<<minInt(attempt, 9)) * time.Second
	cap := 5 * time.Minute
	if d > cap {
		d = cap
	}
	return d
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func (d *Dispatcher) sleep(ctx context.Context, dur time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(dur):
	}
}
