/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   serve.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:37:52 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:37:54 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

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
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/webhooks"
)

// routerDeps carries the dependencies buildRouter wires into the HTTP surface
// (fields are the former positional buildRouter arguments, 1:1).
type routerDeps struct {
	db           *pg.Postgres
	log          *slog.Logger
	svc          *webhooks.Service
	ftSvc        *functriggers.Service
	serviceToken string
	m            *observability.Metrics
}

// buildRouter assembles the HTTP surface: webhook CRUD, function-trigger CRUD,
// and (when VAULT_ENC_KEY is set) the per-function secret store.
func buildRouter(ctx context.Context, d routerDeps) *http.ServeMux {
	mux := httpx.NewRouter("webhook-dispatcher", d.db, d.m)
	webhooks.Mount(mux, d.svc, d.serviceToken)
	functriggers.Mount(mux, d.ftSvc, d.serviceToken)
	mountFuncSecrets(ctx, mux, d.db, d.log, d.serviceToken)
	return mux
}

// newServer builds the HTTP server with the original timeouts and middleware.
func newServer(cfg config.Config, mux *http.ServeMux, log *slog.Logger, m *observability.Metrics) *http.Server {
	return &http.Server{
		Addr:              cfg.ListenAddr(),
		Handler:           httpx.WithMiddleware(mux, log, m),
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

// loopsConfig carries the parameters launchLoops fans out to the server and the
// two dispatcher loops (fields are the former positional launchLoops args, 1:1).
type loopsConfig struct {
	log      *slog.Logger
	redisURL string
	srv      *http.Server
	cfg      config.Config
	wh, ft   func(context.Context) error
	stop     func()
}

// launchLoops starts the HTTP server and both dispatcher loops as goroutines,
// each able to trigger a graceful stop on failure.
func launchLoops(ctx context.Context, c loopsConfig) {
	go serve(c.srv, c.cfg, c.log, c.stop)
	go runLoop(ctx, loopRun{log: c.log, redisURL: c.redisURL, lbl: loopLabels{
		start: "dispatcher loop starting", end: "dispatcher loop ended",
	}, run: c.wh, stop: c.stop})
	go runLoop(ctx, loopRun{log: c.log, redisURL: c.redisURL, lbl: loopLabels{
		start: "function-trigger dispatcher loop starting", end: "function dispatcher loop ended",
	}, run: c.ft, stop: c.stop})
}

// awaitShutdown blocks until ctx is done, then gracefully drains the server.
func awaitShutdown(ctx context.Context, srv *http.Server, log *slog.Logger) {
	<-ctx.Done()
	log.Info("shutdown signal received")
	httpx.GracefulShutdown(srv, log)
}
