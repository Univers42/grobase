// Package main boots the webhook-dispatcher service.
//
// Two responsibilities:
//  1. HTTP API at $WEBHOOK_DISPATCHER_PORT (default 3025) — tenant CRUD on
//     webhook_subscriptions, delivery ledger inspection.
//  2. Background consumer that XREADGROUP's outbox.<aggregate> Redis streams
//     and POSTs HMAC-signed payloads to subscriber URLs with retry + DLQ.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func main() {
	log := shared.NewLogger("webhook-dispatcher")
	cfg, ctx, stop, db := bootstrap(log)
	defer stop()
	defer db.Close()

	redisURL := resolveRedisURL()
	svc, dispatcher, err := buildWebhooks(ctx, db, log, redisURL)
	if err != nil {
		log.Error("dispatcher init failed", "err", err)
		os.Exit(1)
	}
	defer dispatcher.Close()

	ftSvc, ftDispatcher, err := buildFunctriggers(ctx, db, log, redisURL)
	if err != nil {
		log.Error("function dispatcher init failed", "err", err)
		os.Exit(1)
	}
	defer ftDispatcher.Close()

	mux := buildRouter(ctx, db, log, svc, ftSvc, cfg.ServiceToken)
	srv := newServer(cfg, mux, log)
	launchLoops(ctx, log, redisURL, srv, cfg, dispatcher.Run, ftDispatcher.Run, stop)
	awaitShutdown(ctx, srv, log)
}

// bootstrap loads config, dispatches the --healthcheck subcommand, installs the
// signal-cancelled context, and opens the Postgres pool. Any fatal step exits.
func bootstrap(log *slog.Logger) (shared.Config, context.Context, context.CancelFunc, *shared.Postgres) {
	cfg, err := shared.LoadConfig("WEBHOOK_DISPATCHER")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	db, err := shared.NewPostgres(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("postgres connect failed", "err", err)
		stop()
		os.Exit(1)
	}
	return cfg, ctx, stop, db
}

func healthcheck(cfg shared.Config) int {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + cfg.Port + "/health/live")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
