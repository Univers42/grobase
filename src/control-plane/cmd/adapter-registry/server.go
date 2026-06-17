package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
)

// runServer starts the HTTP server and blocks until the context is cancelled,
// then performs a graceful shutdown.
func runServer(ctx context.Context, stop context.CancelFunc, cfg config.Config, mux http.Handler, log *slog.Logger, m *observability.Metrics) {
	srv := &http.Server{
		Addr:              cfg.ListenAddr(),
		Handler:           httpx.WithMiddleware(mux, log, m),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		log.Info("listening", "addr", cfg.ListenAddr(), "mode", cfg.ProductMode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "err", err)
			stop()
		}
	}()
	<-ctx.Done()
	log.Info("shutdown signal received")
	httpx.GracefulShutdown(srv, log)
}
