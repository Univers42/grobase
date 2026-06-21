/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   middleware.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:32 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package httpx

import (
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
)

// reqCtx carries the per-request correlation state from setup (newReqCtx) to the
// deferred finalizer (finish), bundling what would otherwise be 7 parameters.
type reqCtx struct {
	sw          *statusWriter
	r           *http.Request
	log         *slog.Logger
	m           *observability.Metrics
	requestID   string
	traceparent string
	tenantID    string
	start       time.Time
}

// WithMiddleware wraps a handler with panic recovery, cross-plane correlation
// (X-Request-ID + traceparent), and access logging. The correlation id comes
// from Kong at the edge; for direct calls a fallback id is minted so every
// request is traceable. Both values are placed on the request context (so
// downstream outbound calls can forward them via PropagateHeaders) and the
// request id is echoed back to the caller.
func WithMiddleware(next http.Handler, log *slog.Logger, m *observability.Metrics) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rc := newReqCtx(w, r, log, m)
		defer rc.finish()
		next.ServeHTTP(rc.sw, rc.r)
	})
}

// newReqCtx mints the correlation ids, sets the response request-id header, puts
// the correlation on the request context, and resolves the tenant log.
func newReqCtx(w http.ResponseWriter, r *http.Request, log *slog.Logger, m *observability.Metrics) *reqCtx {
	start := time.Now()
	sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
	requestID := r.Header.Get(observability.HeaderRequestID)
	if requestID == "" {
		requestID = observability.NewRequestID()
	}
	traceparent := r.Header.Get(observability.HeaderTraceparent)
	sw.Header().Set(observability.HeaderRequestID, requestID)
	r = r.WithContext(observability.WithCorrelation(r.Context(), requestID, traceparent))
	tenantID := tenantIDFromRequest(r)
	return &reqCtx{
		sw: sw, r: r, log: observability.WithTenant(log, tenantID), m: m,
		requestID: requestID, traceparent: traceparent, tenantID: tenantID, start: start,
	}
}

// finish is the deferred finalizer: recover from a panic, record metrics for
// real API traffic (skipping probe/scrape paths), and emit the access log.
// recover() is valid here because finish is the deferred function itself.
func (rc *reqCtx) finish() {
	if rec := recover(); rec != nil {
		rc.log.Error("panic recovered", "err", rec, "path", rc.r.URL.Path, "request_id", rc.requestID)
		WriteError(rc.sw, http.StatusInternalServerError, "internal_error", "unexpected error")
	}
	if !strings.HasPrefix(rc.r.URL.Path, "/health") && rc.r.URL.Path != "/metrics" {
		rc.m.Observe(rc.r.Method, rc.sw.status, time.Since(rc.start))
		rc.m.ObserveTenant(rc.sw.status, rc.tenantID)
	}
	rc.log.Info("request", "method", rc.r.Method, "path", rc.r.URL.Path, "status", rc.sw.status,
		"ms", time.Since(rc.start).Milliseconds(), "request_id", rc.requestID, "traceparent", rc.traceparent)
}

// tenantIDFromRequest extracts the tenant id carried on an inbound request, or
// "" when none is present. Tenant-scoped routes accept the tenant on
// X-Baas-Tenant-Id (preferred) / X-Tenant-Id — the SAME signal tokenOrSelf
// authorises against — so the log field and the bounded counter share one source
// of truth. "" for untenanted (admin/service-token) requests keeps WithTenant an
// identity no-op for them even when the flag is on.
func tenantIDFromRequest(r *http.Request) string {
	if v := r.Header.Get("X-Baas-Tenant-Id"); v != "" {
		return v
	}
	return r.Header.Get("X-Tenant-Id")
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}
