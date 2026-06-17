package webhooks

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
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
	cfg = cfg.withDefaults()
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

// withDefaults fills the unset config fields with their defaults.
func (cfg DispatcherConfig) withDefaults() DispatcherConfig {
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
	return cfg
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
