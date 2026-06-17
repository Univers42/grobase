package webhooks

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
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
