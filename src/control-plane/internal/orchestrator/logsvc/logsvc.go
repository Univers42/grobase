// Package logsvc is the Go port of the Node log-service (R2 consolidation).
//
// It ingests application log entries, keeps a bounded in-memory ring for quick
// inspection, and forwards batches to Loki — a faithful port of the NestJS
// `LogBufferService` + `LogsController`, so a client cannot tell which runtime
// served it. Running it inside the orchestrator binary (instead of a ~55 MiB
// Node runtime) is the R2 footprint win.
package logsvc

import (
	"context"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
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
		lokiURL:   shared.EnvStr("LOG_SERVICE_LOKI_URL", "http://loki:3100/loki/api/v1/push"),
		batchSize: shared.EnvInt("LOG_SERVICE_LOKI_BATCH_SIZE", 25),
		flushMS:   shared.EnvInt("LOG_SERVICE_LOKI_FLUSH_MS", 1000),
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
