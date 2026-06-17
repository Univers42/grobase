package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/funcsecrets"
	"github.com/dlesieur/mini-baas/control-plane/internal/functriggers"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/webhooks"
)

// resolveRedisURL mirrors the original env precedence: WEBHOOK_REDIS_URL, then
// OUTBOX_REDIS_URL, then the in-cluster default.
func resolveRedisURL() string {
	if u := os.Getenv("WEBHOOK_REDIS_URL"); u != "" {
		return u
	}
	if u := os.Getenv("OUTBOX_REDIS_URL"); u != "" {
		return u
	}
	return "redis://redis:6379"
}

// buildWebhooks wires the webhook subscriptions service and its Redis-backed
// delivery dispatcher.
func buildWebhooks(ctx context.Context, db *pg.Postgres, log *slog.Logger, redisURL string, m *observability.Metrics) (*webhooks.Service, *webhooks.Dispatcher, error) {
	svc := webhooks.NewService(db, log)
	if err := svc.EnsureSchema(ctx); err != nil {
		return nil, nil, err
	}
	dispatcher, err := webhooks.NewDispatcher(db, log, webhooks.DispatcherConfig{
		RedisURL:    redisURL,
		GroupName:   config.EnvStr("WEBHOOK_GROUP", "webhook-dispatcher"),
		ConsumerID:  config.EnvStr("WEBHOOK_CONSUMER", "webhook-dispatcher-0"),
		PollPause:   1 * time.Second,
		RetryPeriod: 10 * time.Second,
	}, m)
	return svc, dispatcher, err
}

// buildFunctriggers wires the DB-event -> function-trigger service and its
// dispatcher. A missing schema is non-fatal (warns, like the original).
func buildFunctriggers(ctx context.Context, db *pg.Postgres, log *slog.Logger, redisURL string) (*functriggers.Service, *functriggers.Dispatcher, error) {
	ftSvc := functriggers.NewService(db, log)
	if err := ftSvc.EnsureSchema(ctx); err != nil {
		log.Warn("function_triggers schema check failed — run migration 035", "err", err)
	}
	d, err := functriggers.NewDispatcher(db, log, functriggers.DispatcherConfig{
		RedisURL:    redisURL,
		GroupName:   config.EnvStr("FUNCTION_TRIGGER_GROUP", "function-dispatcher"),
		ConsumerID:  config.EnvStr("FUNCTION_TRIGGER_CONSUMER", "function-dispatcher-0"),
		RuntimeURL:  config.EnvStr("FUNCTIONS_RUNTIME_URL", "http://functions-runtime:3060"),
		PollPause:   1 * time.Second,
		RetryPeriod: 10 * time.Second,
	})
	return ftSvc, d, err
}

// mountFuncSecrets mounts the per-function secret store when VAULT_ENC_KEY is
// present; absence (or an invalid key) leaves the surface unmounted, matching
// the original behavior exactly.
func mountFuncSecrets(ctx context.Context, mux *http.ServeMux, db *pg.Postgres, log *slog.Logger, serviceToken string) {
	encKey := os.Getenv("VAULT_ENC_KEY")
	if encKey == "" {
		log.Info("function secrets disabled (no VAULT_ENC_KEY)")
		return
	}
	enc, encErr := adapterregistry.NewEncryptor(encKey)
	if encErr != nil {
		log.Warn("function secrets disabled — invalid VAULT_ENC_KEY", "err", encErr)
		return
	}
	secSvc := funcsecrets.NewService(db, enc, log)
	if err := secSvc.EnsureSchema(ctx); err != nil {
		log.Warn("function_secrets schema check failed — run migration 037", "err", err)
	}
	funcsecrets.Mount(mux, secSvc, serviceToken)
	log.Info("function secrets surface mounted")
}

// loopLabels carries the (deliberately asymmetric) start/end log lines so each
// dispatcher keeps its exact original wording.
type loopLabels struct{ start, end string }

// loopRun carries the parameters runLoop needs to drive one dispatcher loop
// (fields are the former positional runLoop arguments, 1:1).
type loopRun struct {
	log      *slog.Logger
	redisURL string
	lbl      loopLabels
	run      func(context.Context) error
	stop     func()
}

// runLoop runs a dispatcher's blocking loop and stops the process on an
// unexpected (non-cancellation) error.
func runLoop(ctx context.Context, r loopRun) {
	r.log.Info(r.lbl.start, "redis", r.redisURL)
	if err := r.run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		r.log.Error(r.lbl.end, "err", err)
		r.stop()
	}
}
