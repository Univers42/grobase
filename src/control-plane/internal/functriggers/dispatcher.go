package functriggers

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
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
	cfg = applyDispatcherDefaults(cfg)
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

// applyDispatcherDefaults fills the zero-value config fields with the wiring
// defaults (consumer group, runtime URL, poll/retry cadence).
func applyDispatcherDefaults(cfg DispatcherConfig) DispatcherConfig {
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
	return cfg
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

func (d *Dispatcher) sleep(ctx context.Context, dur time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(dur):
	}
}
