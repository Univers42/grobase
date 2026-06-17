package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/functriggers"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/webhooks"
)

// buildRouter assembles the HTTP surface: webhook CRUD, function-trigger CRUD,
// and (when VAULT_ENC_KEY is set) the per-function secret store.
func buildRouter(ctx context.Context, db *pg.Postgres, log *slog.Logger, svc *webhooks.Service, ftSvc *functriggers.Service, serviceToken string) *http.ServeMux {
	mux := httpx.NewRouter("webhook-dispatcher", db)
	webhooks.Mount(mux, svc, serviceToken)
	functriggers.Mount(mux, ftSvc, serviceToken)
	mountFuncSecrets(ctx, mux, db, log, serviceToken)
	return mux
}

// newServer builds the HTTP server with the original timeouts and middleware.
func newServer(cfg config.Config, mux *http.ServeMux, log *slog.Logger) *http.Server {
	return &http.Server{
		Addr:              cfg.ListenAddr(),
		Handler:           httpx.WithMiddleware(mux, log),
		ReadHeaderTimeout: 5 * time.Second,
	}
}

// serve runs ListenAndServe and stops the process on an unexpected error.
func serve(srv *http.Server, cfg config.Config, log *slog.Logger, stop func()) {
	log.Info("listening", "addr", cfg.ListenAddr(), "mode", cfg.ProductMode)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("server error", "err", err)
		stop()
	}
}

// launchLoops starts the HTTP server and both dispatcher loops as goroutines,
// each able to trigger a graceful stop on failure.
func launchLoops(ctx context.Context, log *slog.Logger, redisURL string, srv *http.Server, cfg config.Config, wh, ft func(context.Context) error, stop func()) {
	go serve(srv, cfg, log, stop)
	go runLoop(ctx, log, redisURL, loopLabels{
		start: "dispatcher loop starting", end: "dispatcher loop ended",
	}, wh, stop)
	go runLoop(ctx, log, redisURL, loopLabels{
		start: "function-trigger dispatcher loop starting", end: "function dispatcher loop ended",
	}, ft, stop)
}

// awaitShutdown blocks until ctx is done, then gracefully drains the server.
func awaitShutdown(ctx context.Context, srv *http.Server, log *slog.Logger) {
	<-ctx.Done()
	log.Info("shutdown signal received")
	httpx.GracefulShutdown(srv, log)
}
