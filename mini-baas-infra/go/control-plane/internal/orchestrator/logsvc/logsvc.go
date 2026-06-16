// Package logsvc is the Go port of the Node log-service (R2 consolidation).
//
// It ingests application log entries, keeps a bounded in-memory ring for quick
// inspection, and forwards batches to Loki — a faithful port of the NestJS
// `LogBufferService` + `LogsController`, so a client cannot tell which runtime
// served it. Running it inside the orchestrator binary (instead of a ~55 MiB
// Node runtime) is the R2 footprint win.
package logsvc

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

const maxBufferSize = 1000

// Entry is a buffered log line. JSON tags mirror the Node wire shape.
type Entry struct {
	Level     string         `json:"level"`
	Source    string         `json:"source"`
	Message   string         `json:"message"`
	Data      map[string]any `json:"data,omitempty"`
	CreatedAt string         `json:"createdAt"`
}

// Service buffers log entries and flushes them to Loki on a timer / batch fill.
type Service struct {
	log       *slog.Logger
	client    *http.Client
	lokiURL   string
	batchSize int
	flushMS   int

	mu      sync.Mutex
	entries []Entry // ring (last maxBufferSize, for GET /logs)
	queue   []Entry // pending Loki push
}

// New builds the service from env (parity with the Node defaults).
func New(log *slog.Logger) *Service {
	return &Service{
		log:       log,
		client:    &http.Client{Timeout: 5 * time.Second},
		lokiURL:   env("LOG_SERVICE_LOKI_URL", "http://loki:3100/loki/api/v1/push"),
		batchSize: envInt("LOG_SERVICE_LOKI_BATCH_SIZE", 25),
		flushMS:   envInt("LOG_SERVICE_LOKI_FLUSH_MS", 1000),
		entries:   make([]Entry, 0, maxBufferSize),
	}
}

// Name identifies the sub-service to the orchestrator.
func (s *Service) Name() string { return "log" }

// Mount registers the HTTP routes (parity: POST /logs/ingest, GET /logs).
func (s *Service) Mount(mux *http.ServeMux) {
	mux.HandleFunc("POST /logs/ingest", s.handleIngest)
	mux.HandleFunc("GET /logs", s.handleList)
}

// Run flushes on a fixed cadence until the context is cancelled, then drains.
func (s *Service) Run(ctx context.Context) {
	t := time.NewTicker(time.Duration(s.flushMS) * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			s.flush() // final drain on shutdown
			return
		case <-t.C:
			s.flush()
		}
	}
}

// add appends to the ring + queue, returning the stamped entry. Triggers a
// flush when the queue reaches the batch size (matches the Node behavior).
func (s *Service) add(e Entry) (Entry, bool) {
	e.CreatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	s.mu.Lock()
	s.entries = append(s.entries, e)
	if len(s.entries) > maxBufferSize {
		s.entries = s.entries[len(s.entries)-maxBufferSize:]
	}
	s.queue = append(s.queue, e)
	full := len(s.queue) >= s.batchSize
	s.mu.Unlock()
	return e, full
}

func (s *Service) handleIngest(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Level   string         `json:"level"`
		Source  string         `json:"source"`
		Message string         `json:"message"`
		Data    map[string]any `json:"data"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_body"})
		return
	}
	entry, full := s.add(Entry{
		Level:   orDefault(body.Level, "info"),
		Source:  orDefault(body.Source, "unknown"),
		Message: body.Message,
		Data:    body.Data,
	})
	if full {
		go s.flush()
	}
	writeJSON(w, http.StatusOK, map[string]any{"accepted": true, "entry": entry})
}

func (s *Service) handleList(w http.ResponseWriter, r *http.Request) {
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	if limit > maxBufferSize {
		limit = maxBufferSize
	}
	s.mu.Lock()
	n := len(s.entries)
	if limit < n {
		// last `limit` entries
		out := make([]Entry, limit)
		copy(out, s.entries[n-limit:])
		s.mu.Unlock()
		writeJSON(w, http.StatusOK, out)
		return
	}
	out := make([]Entry, n)
	copy(out, s.entries)
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, out)
}

// flush pushes up to batchSize queued entries to Loki. On failure the batch is
// returned to the FRONT of the queue (no loss), mirroring the Node unshift.
func (s *Service) flush() {
	s.mu.Lock()
	if len(s.queue) == 0 {
		s.mu.Unlock()
		return
	}
	n := s.batchSize
	if n > len(s.queue) {
		n = len(s.queue)
	}
	batch := make([]Entry, n)
	copy(batch, s.queue[:n])
	s.queue = s.queue[n:]
	s.mu.Unlock()

	if err := s.push(batch); err != nil {
		s.mu.Lock()
		s.queue = append(batch, s.queue...) // requeue at the front
		s.mu.Unlock()
		s.log.Warn("loki push failed", "err", err)
	}
}

func (s *Service) push(batch []Entry) error {
	streams := make([]map[string]any, 0, len(batch))
	for _, e := range batch {
		streams = append(streams, toLokiStream(e))
	}
	body, err := json.Marshal(map[string]any{"streams": streams})
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, s.lokiURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return &lokiError{status: resp.StatusCode}
	}
	return nil
}

type lokiError struct{ status int }

func (e *lokiError) Error() string { return "loki push returned " + strconv.Itoa(e.status) }

// toLokiStream mirrors the Node `toLokiStream`: one stream per entry, labelled
// by service+level, with the full record (plus request_id promotion) as the line.
func toLokiStream(e Entry) map[string]any {
	t, err := time.Parse(time.RFC3339Nano, e.CreatedAt)
	if err != nil {
		t = time.Now()
	}
	line := map[string]any{
		"service": e.Source,
		"level":   e.Level,
		"message": e.Message,
	}
	for k, v := range e.Data {
		line[k] = v
	}
	if rid, ok := e.Data["request_id"]; ok {
		line["request_id"] = rid
	}
	lineJSON, _ := json.Marshal(line)
	return map[string]any{
		"stream": map[string]any{"service": e.Source, "level": e.Level},
		"values": [][2]string{{strconv.FormatInt(t.UnixNano(), 10), string(lineJSON)}},
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
