/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   boot.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:35:50 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:35:51 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/scheduler"
)

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
func newService(ctx context.Context, db *pg.Postgres, log *slog.Logger) *scheduler.Service {
	svc := scheduler.NewService(db, log)
	if err := svc.EnsureSchema(ctx); err != nil {
		log.Warn("function_schedules schema check failed — run migration 036", "err", err)
	}
	return svc
}

// buildRunner constructs the schedule runner pointed at the functions-runtime.
func buildRunner(db *pg.Postgres, log *slog.Logger, tick time.Duration) *scheduler.Runner {
	return scheduler.NewRunner(db, log, scheduler.RunnerConfig{
		RuntimeURL: config.EnvStr("FUNCTIONS_RUNTIME_URL", "http://functions-runtime:3060"),
		Tick:       tick,
	})
}

// buildServerParams groups the inputs to buildServer (former positional args).
type buildServerParams struct {
	cfg config.Config
	svc *scheduler.Service
	db  *pg.Postgres
	log *slog.Logger
	m   *observability.Metrics
}

// buildServer wires the CRUD router behind shared middleware.
func buildServer(p buildServerParams) *http.Server {
	mux := httpx.NewRouter("function-scheduler", p.db, p.m)
	scheduler.Mount(mux, p.svc, p.cfg.ServiceToken)
	return &http.Server{
		Addr:              p.cfg.ListenAddr(),
		Handler:           httpx.WithMiddleware(mux, p.log, p.m),
		ReadHeaderTimeout: 5 * time.Second,
	}
}
