/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:35:58 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:36:50 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package main is the consolidated Go orchestrator (R2).
//
// The BaaS shipped six small Node orchestrators (email / newsletter / gdpr /
// session / log / outbox-relay), each paying a ~50 MiB Node runtime tax for a
// few hundred lines of glue. R2 folds them into ONE Go binary: each becomes a
// `SubService` mounted on a shared router with a shared background runtime, so
// six runtimes collapse to one (~10–15 MiB total) — the −359 MiB / essential
// $13→$6.5 win in the master plan.
//
// Sub-services are ported one at a time and run in SHADOW (parity-checked
// against the Node original) before the Node container is retired — the same
// shadow→parity→cutover discipline as the data plane. Today: `log`. Selected
// via `ORCHESTRATOR_SERVICES` (comma list; default = every ported service).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/envelope"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// SubService is one consolidated orchestrator module. Mount registers its HTTP
// routes; Run is its (optional) background loop. Both share the host's process,
// router, and lifecycle.
type SubService interface {
	Name() string
	Mount(mux *http.ServeMux)
	Run(ctx context.Context)
}

// initializer is an optional SubService capability: a one-time bootstrap (e.g.
// schema migration) run before the service is mounted, mirroring onModuleInit.
type initializer interface {
	Init(ctx context.Context) error
}

func main() {
	log := observability.NewLogger("orchestrator")
	ctx, stop, cfg, db := boot(log)
	defer stop()
	defer db.Close()
	startPprofIfEnabled(ctx, log)

	available := availableServices(log, db, newQuotaGuard(log, db))
	enabled := selectServices(available, os.Getenv("ORCHESTRATOR_SERVICES"))
	if len(enabled) == 0 {
		log.Error("no sub-services enabled (ORCHESTRATOR_SERVICES matched nothing)")
		os.Exit(1)
	}

	m := observability.NewMetrics()
	mux := httpx.NewRouter("orchestrator", db, m)
	mountServices(ctx, mux, enabled, log)
	serve(ctx, serveParams{cfg: cfg, mux: mux, log: log, stop: stop, m: m})
}

// boot loads config (a --healthcheck argv short-circuits to the probe), wires a
// SIGTERM/SIGINT-cancelled context, and opens the Postgres pool. A failed step
// is fatal — the orchestrator cannot serve without it.
func boot(log *slog.Logger) (context.Context, context.CancelFunc, config.Config, *pg.Postgres) {
	cfg, err := config.LoadConfig("ORCHESTRATOR")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	db, err := pg.NewPostgres(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("postgres connect failed", "err", err)
		stop()
		os.Exit(1)
	}
	return ctx, stop, cfg, db
}

// serveParams groups the non-ctx inputs to serve (former positional args).
type serveParams struct {
	cfg  config.Config
	mux  *http.ServeMux
	log  *slog.Logger
	stop func()
	m    *observability.Metrics
}

// serve runs the HTTP server until ctx is cancelled, then drains gracefully.
// envelope.Wrap mirrors the Node TransformInterceptor so a cutover is
// transparent to clients (Track-2 A parity); WithMiddleware (logging,
// request-id, metrics) wraps that so it still observes the real status.
func serve(ctx context.Context, p serveParams) {
	srv := &http.Server{
		Addr:              p.cfg.ListenAddr(),
		Handler:           httpx.WithMiddleware(envelope.Wrap(p.mux), p.log, p.m),
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
