// Package main boots the function-scheduler service (A2 Functions DX).
//
// Two responsibilities:
//  1. HTTP API at $FUNCTION_SCHEDULER_PORT (default 3026) — tenant CRUD on
//     function_schedules.
//  2. Background runner that polls due schedules and invokes the target
//     function on the functions-runtime, advancing next_run by the schedule's
//     interval.
//
// Schedule grammar is the zero-dep dialect parsed in internal/scheduler (no
// external cron lib is available in go.mod offline): "@every 30s", "@hourly",
// "@daily", or a bare Go duration ("5m"). Parsing + next-run math are
// unit-tested in internal/scheduler.
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/scheduler"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func main() {
	log := shared.NewLogger("function-scheduler")

	cfg, err := shared.LoadConfig("FUNCTION_SCHEDULER")
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

	svc := scheduler.NewService(db, log)
	if err := svc.EnsureSchema(ctx); err != nil {
		log.Warn("function_schedules schema check failed — run migration 036", "err", err)
	}

	tick := 10 * time.Second
	if v := os.Getenv("FUNCTION_SCHEDULER_TICK_SECONDS"); v != "" {
		if n, perr := time.ParseDuration(v + "s"); perr == nil && n > 0 {
			tick = n
		}
	}
	runner := scheduler.NewRunner(db, log, scheduler.RunnerConfig{
		RuntimeURL: shared.EnvStr("FUNCTIONS_RUNTIME_URL", "http://functions-runtime:3060"),
		Tick:       tick,
	})

	mux := shared.NewRouter("function-scheduler", db)
	scheduler.Mount(mux, svc, cfg.ServiceToken)

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

	// LIVE CRON (m96) — flag-gated OFF by default. The runner is the only part
	// that AUTONOMOUSLY invokes functions; gating it OFF keeps the default stack
	// byte-parity (no background invocation fires unless a human opts in). The
	// HTTP CRUD surface above is unaffected, so schedule create/list/delete
	// (exercised by m56 with enabled=false) is unchanged. Set
	// FUNCTIONS_CRON_ENABLED=1 to fire due, enabled schedules.
	if cronEnabled() {
		go func() {
			log.Info("scheduler runner starting (FUNCTIONS_CRON_ENABLED=1)", "tick", tick)
			if err := runner.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
				log.Error("runner ended", "err", err)
				stop()
			}
		}()
	} else {
		log.Info("scheduler runner DISABLED (FUNCTIONS_CRON_ENABLED unset) — CRUD only, no autonomous firing")
	}

	<-ctx.Done()
	log.Info("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
	}
	log.Info("stopped")
}

// cronEnabled reports whether the autonomous schedule runner should start.
// DEFAULT OFF (byte-parity): no background invocation fires unless opted in.
func cronEnabled() bool {
	switch os.Getenv("FUNCTIONS_CRON_ENABLED") {
	case "1", "true", "TRUE", "True", "on", "ON", "yes":
		return true
	default:
		return false
	}
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
