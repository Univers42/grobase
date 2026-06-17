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
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
)

func main() {
	log := observability.NewLogger("function-scheduler")
	cfg, ctx, stop := bootstrap(log)
	defer stop()

	db := mustDial(ctx, cfg, log)
	defer db.Close()
	svc := newService(ctx, db, log)

	tick := resolveTick()
	runner := buildRunner(db, log, tick)
	srv := buildServer(cfg, svc, db, log)

	serve(srv, cfg, log, stop)
	startRunner(ctx, runner, tick, log, stop)

	<-ctx.Done()
	log.Info("shutdown signal received")
	gracefulShutdown(srv, log)
}

// bootstrap loads config (fatal on error), honours the --healthcheck probe arg,
// and returns a signal-cancelled context plus its stop func.
func bootstrap(log *slog.Logger) (config.Config, context.Context, context.CancelFunc) {
	cfg, err := config.LoadConfig("FUNCTION_SCHEDULER")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	return cfg, ctx, stop
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

func healthcheck(cfg config.Config) int {
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
