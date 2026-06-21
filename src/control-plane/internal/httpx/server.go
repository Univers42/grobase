/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   server.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:39 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:40 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package httpx

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// NewRouter builds a base mux with liveness/readiness probes and a Prometheus
// /metrics endpoint. The caller constructs the metrics sink (observability.
// NewMetrics) once and passes it in — one Metrics per process, injected.
func NewRouter(service string, db *pg.Postgres, m *observability.Metrics) *http.ServeMux {
	m.SetService(service)
	mux := http.NewServeMux()

	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		m.WriteProm(w)
	})
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok", "service": service})
	})
	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(r.Context()); err != nil {
			WriteJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "degraded", "error": "db_unreachable"})
			return
		}
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ready", "service": service})
	})
	return mux
}
