package shared

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
)

// G7 (cross-plane correlation). Kong injects X-Request-ID at the edge
// (echo_downstream) and the TS/Rust planes already carry it + W3C traceparent.
// This file closes the Go leg: the middleware lifts both headers into the
// request context, and PropagateHeaders re-emits them on internal outbound
// calls — so a single request is followable TS → Go → Rust through the logs
// (Loki) without a full tracing backend.

const (
	// HeaderRequestID is Kong's correlation header (config.header_name).
	HeaderRequestID = "X-Request-ID"
	// HeaderTraceparent is the W3C trace context header.
	HeaderTraceparent = "traceparent"
)

type ctxKey int

const (
	requestIDKey ctxKey = iota
	traceparentKey
)

// WithCorrelation returns a context carrying the request id + traceparent.
func WithCorrelation(ctx context.Context, requestID, traceparent string) context.Context {
	if requestID != "" {
		ctx = context.WithValue(ctx, requestIDKey, requestID)
	}
	if traceparent != "" {
		ctx = context.WithValue(ctx, traceparentKey, traceparent)
	}
	return ctx
}

// RequestID returns the correlation id carried on ctx, or "".
func RequestID(ctx context.Context) string {
	v, _ := ctx.Value(requestIDKey).(string)
	return v
}

// Traceparent returns the W3C traceparent carried on ctx, or "".
func Traceparent(ctx context.Context) string {
	v, _ := ctx.Value(traceparentKey).(string)
	return v
}

// PropagateHeaders copies the correlation headers from ctx onto an outbound
// request so the next plane logs the same id. No-op for values not present.
func PropagateHeaders(ctx context.Context, req *http.Request) {
	if id := RequestID(ctx); id != "" {
		req.Header.Set(HeaderRequestID, id)
	}
	if tp := Traceparent(ctx); tp != "" {
		req.Header.Set(HeaderTraceparent, tp)
	}
}

// newRequestID mints a fallback correlation id for requests that reach a Go
// service directly (not via Kong), so every request log line has one.
func newRequestID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "unknown"
	}
	return hex.EncodeToString(b[:])
}
