/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:35:42 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:35:43 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package main boots the Go control-plane adapter-registry service.
//
// This is the control-plane replacement for the NestJS adapter-registry app.
// It owns the tenant database registry: encrypted connection-string storage
// (AES-256-GCM, byte-compatible with the legacy Node CryptoService) and the
// metadata CRUD that the Rust data plane resolves mounts against.
package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// main boots the adapter-registry: load config, open Postgres, build the
// service, mount the routes, and serve until SIGTERM/SIGINT. A "--healthcheck"
// first arg short-circuits to the probe mode used by the container HEALTHCHECK
// (without a shell) and exits with its status.
func main() {
	log := observability.NewLogger("adapter-registry")
	cfg, err := config.LoadConfig("ADAPTER_REGISTRY")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	db := pg.MustPostgres(ctx, cfg.DatabaseURL, log)
	defer db.Close()
	m := observability.NewMetrics()
	svc := buildService(ctx, db, log)
	mux := httpx.NewRouter("adapter-registry", db, m)
	adapterregistry.Mount(mux, svc, cfg.ServiceToken)
	runServer(ctx, runServerParams{stop: stop, cfg: cfg, mux: mux, log: log, m: m})
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
