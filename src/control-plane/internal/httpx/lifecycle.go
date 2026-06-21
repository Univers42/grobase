/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lifecycle.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:29 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:30 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package httpx

import (
	"context"
	"log/slog"
	"net/http"
	"time"
)

// GracefulShutdown drains the HTTP server within a bounded 10s window and logs
// the outcome. The caller logs "shutdown signal received" at the point it
// decides to stop (which varies by daemon), then calls this to drain.
func GracefulShutdown(srv *http.Server, log *slog.Logger) {
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
	}
	log.Info("stopped")
}
