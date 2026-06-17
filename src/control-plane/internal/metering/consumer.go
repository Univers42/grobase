package metering

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	redis "github.com/redis/go-redis/v9"
)

// FROZEN stream contract (both planes MUST match): a single stream keyed
// "usage.events" (the metric is a field, not the stream name), consumed by a
// durable consumer group so re-delivery is at-least-once and the store dedups on
// idempotency_key.
const (
	usageStream   = "usage.events"
	usageGroup    = "metering-ingest"
	usageConsumer = "control-plane"
)

// Consumer is the metering ingest sub-service. It satisfies the orchestrator
// SubService interface (Name/Mount/Run) + the optional initializer (Init).
//
// FLAG-GATED OFF = PARITY: the consumer only subscribes when METERING_INGEST is
// truthy. With the flag off (the default) Init connects nothing, Run returns
// immediately, and no Redis consumer group is created — the control plane is
// byte-identical to today even though the service is registered.
type Consumer struct {
	log      *slog.Logger
	store    *Store
	rdb      *redis.Client
	enabled  bool
	redisURL string

	blockWait time.Duration // XREADGROUP BLOCK timeout
	batchSize int64         // XREADGROUP COUNT
}

// New builds the consumer from env, mirroring the outbox-relay Redis config so
// the two share one Redis URL convention. METERING_INGEST gates everything; the
// master METERING_ENABLED is honored too (either OFF ⇒ disabled), so a single
// master switch can disable the whole pipeline without touching sub-flags.
func New(log *slog.Logger, db *shared.Postgres) *Consumer {
	return &Consumer{
		log:       log,
		store:     NewStore(db),
		enabled:   envBool("METERING_ENABLED") && envBool("METERING_INGEST"),
		redisURL:  env("OUTBOX_REDIS_URL", env("REDIS_URL", "redis://redis:6379")),
		blockWait: time.Duration(envInt("METERING_INGEST_BLOCK_MS", 2_000)) * time.Millisecond,
		batchSize: int64(envInt("METERING_INGEST_BATCH", 100)),
	}
}

// Name identifies the sub-service to the orchestrator.
func (c *Consumer) Name() string { return "metering" }

// Mount adds no HTTP routes — the consumer is a background worker (the read-back
// API is B1c's handler.go).
func (c *Consumer) Mount(_ *http.ServeMux) {}

// Init connects Redis and ensures the consumer group exists, ONLY when enabled.
// Disabled ⇒ no connection, no group creation ⇒ parity. A failed connect when
// enabled is fatal (the service cannot ingest), matching the outbox-relay Init
// contract. The PARITY guard is the first line: when off this returns nil before
// touching any infra.
func (c *Consumer) Init(ctx context.Context) error {
	if !c.enabled {
		c.log.Info("metering ingest disabled (METERING_INGEST off) — no subscription")
		return nil
	}
	opts, err := redis.ParseURL(c.redisURL)
	if err != nil {
		return err
	}
	opts.MaxRetries = 1
	c.rdb = redis.NewClient(opts)
	if err := c.rdb.Ping(ctx).Err(); err != nil {
		return err
	}
	// MKSTREAM creates the stream if the producers haven't yet; BUSYGROUP means
	// the group already exists (idempotent, not an error).
	if err := c.rdb.XGroupCreateMkStream(ctx, usageStream, usageGroup, "0").Err(); err != nil &&
		!isBusyGroup(err) {
		return err
	}
	c.log.Info("metering ingest connected", "stream", usageStream, "group", usageGroup)
	return nil
}

// Run is the read loop: block-read new entries for the group, upsert each, ack.
// Disabled ⇒ returns immediately (no loop, no subscription) ⇒ parity. Stops on
// ctx cancellation. A poison (malformed) entry is acked + skipped so it cannot
// wedge the group; a DB error leaves the entry un-acked for redelivery.
func (c *Consumer) Run(ctx context.Context) {
	if !c.enabled || c.rdb == nil {
		return
	}
	defer func() { _ = c.rdb.Close() }()
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		streams, err := c.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
			Group:    usageGroup,
			Consumer: usageConsumer,
			Streams:  []string{usageStream, ">"},
			Count:    c.batchSize,
			Block:    c.blockWait,
		}).Result()
		if err != nil {
			if errors.Is(err, redis.Nil) || errors.Is(err, context.Canceled) {
				continue // BLOCK timeout with no new entries — normal idle
			}
			if ctx.Err() != nil {
				return
			}
			c.log.Warn("metering XReadGroup failed", "err", err)
			c.backoff(ctx)
			continue
		}
		for _, st := range streams {
			c.drain(ctx, st.Messages)
		}
	}
}

// drain ingests a batch of messages, acking each one it has durably handled.
func (c *Consumer) drain(ctx context.Context, msgs []redis.XMessage) {
	for _, m := range msgs {
		if err := c.store.Upsert(ctx, m.Values); err != nil {
			if errors.Is(err, errBadEntry) {
				// Poison entry: ack + skip so it never wedges the group.
				c.log.Warn("metering skipping malformed entry", "id", m.ID)
				_ = c.rdb.XAck(ctx, usageStream, usageGroup, m.ID).Err()
				continue
			}
			// Transient DB error: leave un-acked for redelivery (dedup on the
			// idempotency_key makes a redelivered identical window a no-op).
			c.log.Warn("metering upsert failed — will redeliver", "id", m.ID, "err", err)
			continue
		}
		if err := c.rdb.XAck(ctx, usageStream, usageGroup, m.ID).Err(); err != nil {
			c.log.Warn("metering ack failed", "id", m.ID, "err", err)
		}
	}
}

// backoff sleeps briefly on a Redis error, honoring ctx cancellation.
func (c *Consumer) backoff(ctx context.Context) {
	t := time.NewTimer(time.Second)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

// isBusyGroup reports whether err is the benign "group already exists" reply.
func isBusyGroup(err error) bool {
	return err != nil && len(err.Error()) >= 9 && err.Error()[:9] == "BUSYGROUP"
}

/* ─────── env helpers (mirroring outboxrelay) ─────── */

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// envBool mirrors the data-plane config.rs flag shape (matches!(…,"1"|"true"|"on")).
func envBool(key string) bool {
	switch os.Getenv(key) {
	case "1", "true", "on", "TRUE", "True", "ON":
		return true
	default:
		return false
	}
}
