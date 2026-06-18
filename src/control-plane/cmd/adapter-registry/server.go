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

// runServerParams groups the non-ctx inputs to runServer (former positional args).
type runServerParams struct {
	stop context.CancelFunc
	cfg  config.Config
	mux  http.Handler
	log  *slog.Logger
	m    *observability.Metrics
}

// runServer starts the HTTP server and blocks until the context is cancelled,
// then performs a graceful shutdown.
func runServer(ctx context.Context, p runServerParams) {
	srv := &http.Server{
		Addr:              p.cfg.ListenAddr(),
		Handler:           httpx.WithMiddleware(p.mux, p.log, p.m),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		p.log.Info("listening", "addr", p.cfg.ListenAddr(), "mode", p.cfg.ProductMode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			p.log.Error("server error", "err", err)
			p.stop()
		}
	}()
	<-ctx.Done()
	p.log.Info("shutdown signal received")
	httpx.GracefulShutdown(srv, p.log)
}
