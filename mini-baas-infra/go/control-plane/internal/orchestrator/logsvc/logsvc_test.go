package logsvc

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestSvc() *Service {
	s := New(slog.Default())
	s.batchSize = 100 // keep flush out of these unit tests
	return s
}

func TestIngestStampsAndDefaults(t *testing.T) {
	s := newTestSvc()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/logs/ingest",
		strings.NewReader(`{"message":"hi"}`))
	s.handleIngest(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var out struct {
		Accepted bool  `json:"accepted"`
		Entry    Entry `json:"entry"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if !out.Accepted {
		t.Fatal("expected accepted=true")
	}
	if out.Entry.Level != "info" || out.Entry.Source != "unknown" {
		t.Fatalf("defaults not applied: %+v", out.Entry)
	}
	if out.Entry.CreatedAt == "" {
		t.Fatal("createdAt must be stamped")
	}
}

func TestListReturnsLastN(t *testing.T) {
	s := newTestSvc()
	for i := 0; i < 5; i++ {
		s.add(Entry{Level: "info", Source: "t", Message: string(rune('a' + i))})
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/logs?limit=2", nil)
	s.handleList(rec, req)

	var out []Entry
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(out))
	}
	if out[1].Message != "e" {
		t.Fatalf("expected last entry 'e', got %q", out[1].Message)
	}
}

func TestRingBufferBounded(t *testing.T) {
	s := newTestSvc()
	for i := 0; i < maxBufferSize+50; i++ {
		s.add(Entry{Level: "info", Source: "t", Message: "x"})
	}
	s.mu.Lock()
	n := len(s.entries)
	s.mu.Unlock()
	if n != maxBufferSize {
		t.Fatalf("ring must cap at %d, got %d", maxBufferSize, n)
	}
}

func TestFlushPushesToLokiAndRequeuesOnFailure(t *testing.T) {
	// First a server that 200s: the queue drains.
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if _, has := body["streams"]; !has {
			t.Error("loki payload missing streams")
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer ok.Close()

	s := newTestSvc()
	s.lokiURL = ok.URL
	s.batchSize = 10
	s.add(Entry{Level: "info", Source: "t", Message: "a"})
	s.flush()
	s.mu.Lock()
	qlen := len(s.queue)
	s.mu.Unlock()
	if qlen != 0 {
		t.Fatalf("queue should drain on 2xx, got %d", qlen)
	}

	// Now a server that 500s: the batch is requeued (no loss).
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer bad.Close()
	s.lokiURL = bad.URL
	s.add(Entry{Level: "info", Source: "t", Message: "b"})
	s.flush()
	s.mu.Lock()
	qlen = len(s.queue)
	s.mu.Unlock()
	if qlen != 1 {
		t.Fatalf("failed push must requeue, queue=%d", qlen)
	}
}

func TestToLokiStreamShape(t *testing.T) {
	stream := toLokiStream(Entry{
		Level: "warn", Source: "svc", Message: "boom",
		Data: map[string]any{"request_id": "r1", "extra": 2}, CreatedAt: "2026-06-11T00:00:00Z",
	})
	labels := stream["stream"].(map[string]any)
	if labels["service"] != "svc" || labels["level"] != "warn" {
		t.Fatalf("labels wrong: %+v", labels)
	}
	vals := stream["values"].([][2]string)
	if len(vals) != 1 {
		t.Fatalf("expected 1 value tuple, got %d", len(vals))
	}
	var line map[string]any
	if err := json.Unmarshal([]byte(vals[0][1]), &line); err != nil {
		t.Fatal(err)
	}
	if line["message"] != "boom" || line["request_id"] != "r1" || line["extra"] != float64(2) {
		t.Fatalf("line body wrong: %+v", line)
	}
}
