// Package outboxrelay is the Go port of the Node outbox-relay (R2 consolidation).
//
// It drains the transactional outbox (public.outbox_events) and relays each
// event to Redis streams + the realtime fan-out, runs the saga dispatch /
// compensation lifecycle, and (when a Mongo projector is wired) maintains read
// projections — a faithful port of the NestJS OutboxRelayService +
// SagaCoordinatorService. It is the heaviest Node service (ioredis + mongodb +
// prom-client → ~256 MiB), so folding it into the orchestrator binary is the
// single biggest R2 footprint win.
//
// Mongo is a SOFT dependency exactly as in the Node service (MONGO_OPTIONAL): a
// deployment without Mongo skips projections loudly and the canonical pg write
// still relays to Redis + realtime. The default projector is the no-op (Mongo
// unavailable); a real Mongo projector is a follow-up slice — until it lands the
// Node relay stays the cutover owner for Mongo-backed projections (shadow
// discipline).
package outboxrelay

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	redis "github.com/redis/go-redis/v9"
)

// Service is the outbox-relay sub-service.
type Service struct {
	log      *slog.Logger
	pg       *pg.Postgres
	rdb      *redis.Client
	project  projector
	client   *http.Client
	redisURL string
	mongoURL string

	pollEvery    time.Duration
	batchSize    int
	maxAttempts  int
	dedupeTTL    time.Duration
	realtimeURL  string
	realtimeWait time.Duration

	// scale metrics (dependency-free; logged each tick — full prom-name parity
	// with mini_baas_outbox_* is a follow-up).
	pending int64
	dead    int64
}

// New builds the service from env (parity with the Node defaults).
func New(log *slog.Logger, pg *pg.Postgres) *Service {
	return &Service{
		log:          log,
		pg:           pg,
		project:      noopProjector{log: log},
		client:       &http.Client{},
		redisURL:     config.EnvStr("OUTBOX_REDIS_URL", config.EnvStr("REDIS_URL", "redis://redis:6379")),
		mongoURL:     os.Getenv("OUTBOX_MONGO_URL"),
		pollEvery:    time.Duration(config.EnvInt("OUTBOX_RELAY_POLL_MS", 500)) * time.Millisecond,
		batchSize:    config.EnvInt("OUTBOX_RELAY_BATCH_SIZE", 25),
		maxAttempts:  config.EnvInt("OUTBOX_RELAY_MAX_ATTEMPTS", 5),
		dedupeTTL:    time.Duration(config.EnvInt("OUTBOX_RELAY_DEDUPE_TTL_SECONDS", 86_400)) * time.Second,
		realtimeURL:  os.Getenv("REALTIME_PUBLISH_URL"),
		realtimeWait: time.Duration(config.EnvInt("REALTIME_PUBLISH_TIMEOUT_MS", 1_000)) * time.Millisecond,
	}
}

// Name identifies the sub-service to the orchestrator.
func (s *Service) Name() string { return "outbox-relay" }

// Init connects Redis before the poll loop starts (parity with onModuleInit).
// The outbox_events table itself is owned by migrations, not created here. Mongo
// is a SOFT dependency (parity with MONGO_OPTIONAL): the driver-backed projector
// is selected only when OUTBOX_MONGO_URL is set AND a connection succeeds;
// otherwise the no-op projector is kept so a deployment without Mongo (lean /
// single-tenant CRUD tiers) boots degraded and skips projections loudly. A Mongo
// connect failure never blocks Init.
func (s *Service) Init(ctx context.Context) error {
	opts, err := redis.ParseURL(s.redisURL)
	if err != nil {
		return err
	}
	opts.MaxRetries = 1
	s.rdb = redis.NewClient(opts)
	if err := s.rdb.Ping(ctx).Err(); err != nil {
		return err
	}
	s.log.Info("outbox relay redis connected")
	if p, ok := newMongoProjector(ctx, s.log, s.mongoURL); ok {
		s.project = p
	}
	return nil
}

// Mount adds no HTTP routes (health/metrics are the shared router's); the relay
// is a background worker.
func (s *Service) Mount(_ *http.ServeMux) {}

// Run is the poll loop: every pollEvery, drain a batch, after an immediate first
// drain (parity with the Node await this.tick()). A tick is skipped if the
// previous one is still running (the loop is single-threaded, so serialization
// is implicit). Stops on ctx cancellation.
func (s *Service) Run(ctx context.Context) {
	ticker := time.NewTicker(s.pollEvery)
	defer ticker.Stop()
	s.tick(ctx)
	for {
		select {
		case <-ctx.Done():
			if s.rdb != nil {
				_ = s.rdb.Close()
			}
			if mp, ok := s.project.(*mongoProjector); ok {
				mp.close(context.Background())
			}
			return
		case <-ticker.C:
			s.tick(ctx)
		}
	}
}
