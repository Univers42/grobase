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
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/dlesieur/mini-baas/control-plane/internal/funcsecrets"
	"github.com/dlesieur/mini-baas/control-plane/internal/functriggers"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/webhooks"
)

func main() {
	log := shared.NewLogger("webhook-dispatcher")

	cfg, err := shared.LoadConfig("WEBHOOK_DISPATCHER")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}

	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	db, err := shared.NewPostgres(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("postgres connect failed", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	svc := webhooks.NewService(db, log)
	if err := svc.EnsureSchema(ctx); err != nil {
		log.Error("schema check failed", "err", err)
		os.Exit(1)
	}

	redisURL := os.Getenv("WEBHOOK_REDIS_URL")
	if redisURL == "" {
		redisURL = os.Getenv("OUTBOX_REDIS_URL")
	}
	if redisURL == "" {
		redisURL = "redis://redis:6379"
	}

	dispatcher, err := webhooks.NewDispatcher(db, log, webhooks.DispatcherConfig{
		RedisURL:    redisURL,
		GroupName:   envDefault("WEBHOOK_GROUP", "webhook-dispatcher"),
		ConsumerID:  envDefault("WEBHOOK_CONSUMER", "webhook-dispatcher-0"),
		PollPause:   1 * time.Second,
		RetryPeriod: 10 * time.Second,
	})
	if err != nil {
		log.Error("dispatcher init failed", "err", err)
		os.Exit(1)
	}
	defer dispatcher.Close()

	// A2: DB-event -> function triggers. Shares the same DB + Redis substrate
	// and reuses the identical matching + retry/DLQ machinery; the only
	// difference is the delivery target (functions-runtime invoke).
	ftSvc := functriggers.NewService(db, log)
	if err := ftSvc.EnsureSchema(ctx); err != nil {
		log.Warn("function_triggers schema check failed — run migration 035", "err", err)
	}
	ftDispatcher, err := functriggers.NewDispatcher(db, log, functriggers.DispatcherConfig{
		RedisURL:    redisURL,
		GroupName:   envDefault("FUNCTION_TRIGGER_GROUP", "function-dispatcher"),
		ConsumerID:  envDefault("FUNCTION_TRIGGER_CONSUMER", "function-dispatcher-0"),
		RuntimeURL:  envDefault("FUNCTIONS_RUNTIME_URL", "http://functions-runtime:3060"),
		PollPause:   1 * time.Second,
		RetryPeriod: 10 * time.Second,
	})
	if err != nil {
		log.Error("function dispatcher init failed", "err", err)
		os.Exit(1)
	}
	defer ftDispatcher.Close()

	mux := shared.NewRouter("webhook-dispatcher", db)
	webhooks.Mount(mux, svc, cfg.ServiceToken)
	functriggers.Mount(mux, ftSvc, cfg.ServiceToken)

	// A2: per-function secret store. Requires VAULT_ENC_KEY (same master key as
	// the adapter-registry); if absent, the secrets surface is simply not
	// mounted — function triggers/schedules still work without it.
	if encKey := os.Getenv("VAULT_ENC_KEY"); encKey != "" {
		enc, encErr := adapterregistry.NewEncryptor(encKey)
		if encErr != nil {
			log.Warn("function secrets disabled — invalid VAULT_ENC_KEY", "err", encErr)
		} else {
			secSvc := funcsecrets.NewService(db, enc, log)
			if err := secSvc.EnsureSchema(ctx); err != nil {
				log.Warn("function_secrets schema check failed — run migration 037", "err", err)
			}
			funcsecrets.Mount(mux, secSvc, cfg.ServiceToken)
			log.Info("function secrets surface mounted")
		}
	} else {
		log.Info("function secrets disabled (no VAULT_ENC_KEY)")
	}

	srv := &http.Server{
		Addr:              cfg.ListenAddr(),
		Handler:           shared.WithMiddleware(mux, log),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Info("listening", "addr", cfg.ListenAddr(), "mode", cfg.ProductMode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "err", err)
			stop()
		}
	}()

	go func() {
		log.Info("dispatcher loop starting", "redis", redisURL)
		if err := dispatcher.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Error("dispatcher loop ended", "err", err)
			stop()
		}
	}()

	go func() {
		log.Info("function-trigger dispatcher loop starting", "redis", redisURL)
		if err := ftDispatcher.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Error("function dispatcher loop ended", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Info("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
	}
	log.Info("stopped")
}

func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
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
