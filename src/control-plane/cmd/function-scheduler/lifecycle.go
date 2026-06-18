package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/scheduler"
)

// serve runs the HTTP listener in the background, signalling stop on fatal error.
func serve(srv *http.Server, cfg config.Config, log *slog.Logger, stop func()) {
	go func() {
		log.Info("listening", "addr", cfg.ListenAddr(), "mode", cfg.ProductMode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "err", err)
			stop()
		}
	}()
}

// startRunner launches the autonomous schedule runner ONLY when cron is enabled.
// LIVE CRON (m96) — flag-gated OFF by default. The runner is the only part that
// AUTONOMOUSLY invokes functions; gating it OFF keeps the default stack
// byte-parity (no background invocation fires unless a human opts in). The HTTP
// CRUD surface is unaffected, so schedule create/list/delete (exercised by m56
// with enabled=false) is unchanged. Set FUNCTIONS_CRON_ENABLED=1 to fire due,
// enabled schedules.
func startRunner(ctx context.Context, runner *scheduler.Runner, tick time.Duration, log *slog.Logger, stop func()) {
	if !cronEnabled() {
		log.Info("scheduler runner DISABLED (FUNCTIONS_CRON_ENABLED unset) — CRUD only, no autonomous firing")
		return
	}
	go func() {
		log.Info("scheduler runner starting (FUNCTIONS_CRON_ENABLED=1)", "tick", tick)
		if err := runner.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Error("runner ended", "err", err)
			stop()
		}
	}()
}
