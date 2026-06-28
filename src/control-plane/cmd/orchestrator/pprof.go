/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   pprof.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	nhpprof "net/http/pprof"
	"runtime"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
)

// startPprofIfEnabled starts a LOOPBACK-only diagnostics server (Go pprof plus a
// /debug/memstats snapshot) when CONTROL_PLANE_PPROF_ENABLED is truthy. OFF by
// default — a missing var is byte-parity with the OSS edition. Bound to
// CONTROL_PLANE_PPROF_ADDR (default 127.0.0.1:6060) so heap/goroutine profiles
// are never reachable off-box. No-op when disabled.
func startPprofIfEnabled(ctx context.Context, log *slog.Logger) {
	if !config.EnvBool("CONTROL_PLANE_PPROF_ENABLED") {
		return
	}
	srv := &http.Server{
		Addr:              config.EnvStr("CONTROL_PLANE_PPROF_ADDR", "127.0.0.1:6060"),
		Handler:           newPprofMux(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go runPprofServer(ctx, srv, log)
}

// newPprofMux wires the Go pprof handlers and a /debug/memstats JSON endpoint
// onto a PRIVATE mux — never the global DefaultServeMux, never the public router
// — so profiling endpoints stay isolated to the loopback diagnostics listener.
func newPprofMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", nhpprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", nhpprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", nhpprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", nhpprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", nhpprof.Trace)
	mux.HandleFunc("/debug/memstats", handleMemStats)
	return mux
}

// handleMemStats serves a runtime.MemStats snapshot as JSON — the cheap,
// always-available companion to the pprof heap profile for a quick RSS/heap read
// without capturing a full profile.
func handleMemStats(w http.ResponseWriter, _ *http.Request) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(&ms); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

// runPprofServer serves until ctx is cancelled, then drains with a short
// timeout. A listen error is logged, never fatal: diagnostics must not be able
// to take the orchestrator down.
func runPprofServer(ctx context.Context, srv *http.Server, log *slog.Logger) {
	go func() {
		log.Info("pprof diagnostics listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("pprof server error", "err", err)
		}
	}()
	<-ctx.Done()
	sctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(sctx)
}
