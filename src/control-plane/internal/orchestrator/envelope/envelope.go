// Package envelope mirrors the Node services' global TransformInterceptor
// (src/libs/common/src/interceptors/transform.interceptor.ts) for the Go
// orchestrator, so a client cannot tell whether the legacy Node container or
// the consolidated Go binary answered — the parity requirement that lets the
// Node orchestrators be retired (Track-2 A). Only the orchestrator mux is
// wrapped; the other control-plane daemons (tenant-control, adapter-registry,
// webhook-dispatcher) talk to the gateway and deliberately stay envelope-free.
package envelope

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// methodMessages reproduces METHOD_MESSAGES from the interceptor exactly.
var methodMessages = map[string]map[int]string{
	http.MethodGet:    {200: "Data retrieved successfully"},
	http.MethodPost:   {201: "Resource created successfully", 200: "Operation successful"},
	http.MethodPut:    {200: "Resource updated successfully"},
	http.MethodPatch:  {200: "Resource updated successfully"},
	http.MethodDelete: {200: "Resource deleted successfully"},
}

func message(method string, status int) string {
	if m, ok := methodMessages[method][status]; ok {
		return m
	}
	return "Operation successful"
}

// Wrap mirrors the Nest TransformInterceptor: every 2xx JSON response becomes
// { success, statusCode, message, data, path, timestamp }. Untouched (verbatim
// passthrough): non-2xx (the error filter owns those), non-JSON bodies, and the
// /metrics + /health* operational endpoints (the interceptor skips /metrics;
// health probes must stay a bare body for the container HEALTHCHECK).
func Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/metrics" || strings.HasPrefix(r.URL.Path, "/health") {
			next.ServeHTTP(w, r)
			return
		}
		c := &capture{header: http.Header{}, status: http.StatusOK}
		next.ServeHTTP(c, r)

		body := c.buf.Bytes()
		out, err := buildEnvelope(r, c, body)
		if out == nil || err != nil { // passthrough; never lose the body
			writeVerbatim(w, c, body)
			return
		}
		copyHeader(w.Header(), c.header)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(out)))
		w.WriteHeader(c.status)
		_, _ = w.Write(out)
	})
}

// buildEnvelope returns the wrapped { success,… } body, or (nil,nil) when the
// response must pass through verbatim (non-2xx, non-JSON, or invalid body).
func buildEnvelope(r *http.Request, c *capture, body []byte) ([]byte, error) {
	ct := c.header.Get("Content-Type")
	if c.status < 200 || c.status >= 300 ||
		!strings.Contains(ct, "application/json") || !json.Valid(body) {
		return nil, nil
	}
	return json.Marshal(map[string]any{
		"success":    true,
		"statusCode": c.status,
		"message":    message(r.Method, c.status),
		"data":       json.RawMessage(body), // verbatim — never re-parse the payload
		"path":       r.URL.RequestURI(),
		// JS new Date().toISOString() form: millis + literal Z.
		"timestamp": time.Now().UTC().Format("2006-01-02T15:04:05.000") + "Z",
	})
}
