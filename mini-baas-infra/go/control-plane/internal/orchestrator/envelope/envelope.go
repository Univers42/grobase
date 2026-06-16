// Package envelope mirrors the Node services' global TransformInterceptor
// (src/libs/common/src/interceptors/transform.interceptor.ts) for the Go
// orchestrator, so a client cannot tell whether the legacy Node container or
// the consolidated Go binary answered — the parity requirement that lets the
// Node orchestrators be retired (Track-2 A). Only the orchestrator mux is
// wrapped; the other control-plane daemons (tenant-control, adapter-registry,
// webhook-dispatcher) talk to the gateway and deliberately stay envelope-free.
package envelope

import (
	"bytes"
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

// capture buffers a handler's response so the body can be re-wrapped.
type capture struct {
	header http.Header
	buf    bytes.Buffer
	status int
	wrote  bool
}

func (c *capture) Header() http.Header { return c.header }
func (c *capture) WriteHeader(s int)   { c.status = s; c.wrote = true }
func (c *capture) Write(b []byte) (int, error) {
	if !c.wrote {
		c.status = http.StatusOK // net/http implicit-200 on first Write
		c.wrote = true
	}
	return c.buf.Write(b)
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
		ct := c.header.Get("Content-Type")
		passthrough := c.status < 200 || c.status >= 300 ||
			!strings.Contains(ct, "application/json") || !json.Valid(body)

		if passthrough {
			copyHeader(w.Header(), c.header)
			w.WriteHeader(c.status)
			_, _ = w.Write(body)
			return
		}

		out, err := json.Marshal(map[string]any{
			"success":    true,
			"statusCode": c.status,
			"message":    message(r.Method, c.status),
			"data":       json.RawMessage(body), // verbatim — never re-parse the payload
			"path":       r.URL.RequestURI(),
			// JS new Date().toISOString() form: millis + literal Z.
			"timestamp": time.Now().UTC().Format("2006-01-02T15:04:05.000") + "Z",
		})
		if err != nil { // unreachable for valid JSON data, but never lose the body
			copyHeader(w.Header(), c.header)
			w.WriteHeader(c.status)
			_, _ = w.Write(body)
			return
		}
		copyHeader(w.Header(), c.header)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(out)))
		w.WriteHeader(c.status)
		_, _ = w.Write(out)
	})
}

func copyHeader(dst, src http.Header) {
	for k, vs := range src {
		// Content-Length/Type are re-set by Wrap on the wrapped path.
		if k == "Content-Length" {
			continue
		}
		for _, v := range vs {
			dst.Add(k, v)
		}
	}
}
