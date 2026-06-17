package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/scheduler"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// mustDial opens the Postgres pool or exits non-zero (startup is fatal-on-fail).
func mustDial(ctx context.Context, cfg shared.Config, log *slog.Logger) *shared.Postgres {
	db, err := shared.NewPostgres(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("postgres connect failed", "err", err)
		os.Exit(1)
	}
	return db
}

// resolveTick reads FUNCTION_SCHEDULER_TICK_SECONDS (a bare seconds count),
// falling back to 10s when unset, unparseable, or non-positive.
func resolveTick() time.Duration {
	tick := 10 * time.Second
	if v := os.Getenv("FUNCTION_SCHEDULER_TICK_SECONDS"); v != "" {
		if n, perr := time.ParseDuration(v + "s"); perr == nil && n > 0 {
			tick = n
		}
	}
	return tick
}

// newService builds the schedule service and best-effort-checks its schema
// (a failed check warns and continues — migration 036 owns the DDL).
func newService(ctx context.Context, db *shared.Postgres, log *slog.Logger) *scheduler.Service {
	svc := scheduler.NewService(db, log)
	if err := svc.EnsureSchema(ctx); err != nil {
		log.Warn("function_schedules schema check failed — run migration 036", "err", err)
	}
	return svc
}

// buildRunner constructs the schedule runner pointed at the functions-runtime.
func buildRunner(db *shared.Postgres, log *slog.Logger, tick time.Duration) *scheduler.Runner {
	return scheduler.NewRunner(db, log, scheduler.RunnerConfig{
		RuntimeURL: shared.EnvStr("FUNCTIONS_RUNTIME_URL", "http://functions-runtime:3060"),
		Tick:       tick,
	})
}

// buildServer wires the CRUD router behind shared middleware.
func buildServer(cfg shared.Config, svc *scheduler.Service, db *shared.Postgres, log *slog.Logger) *http.Server {
	mux := shared.NewRouter("function-scheduler", db)
	scheduler.Mount(mux, svc, cfg.ServiceToken)
	return &http.Server{
		Addr:              cfg.ListenAddr(),
		Handler:           shared.WithMiddleware(mux, log),
		ReadHeaderTimeout: 5 * time.Second,
	}
}
