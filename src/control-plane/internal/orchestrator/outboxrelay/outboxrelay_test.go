package outboxrelay

import (
	"context"
	"encoding/json"
	"log/slog"
	"reflect"
	"testing"
)

func TestPayloadObject(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want map[string]any
	}{
		{"object", `{"a":1,"b":"x"}`, map[string]any{"a": float64(1), "b": "x"}},
		{"array_wrapped", `[1,2,3]`, map[string]any{"value": []any{float64(1), float64(2), float64(3)}}},
		{"scalar_wrapped", `42`, map[string]any{"value": float64(42)}},
		{"null_wrapped", `null`, map[string]any{"value": nil}},
		{"empty_wrapped", ``, map[string]any{"value": nil}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := payloadObject(json.RawMessage(c.in))
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("payloadObject(%s) = %v, want %v", c.in, got, c.want)
			}
		})
	}
}

func TestNextFailureStatus(t *testing.T) {
	cases := []struct {
		attempts, max int
		wantStatus    string
		wantDead      bool
	}{
		{0, 5, "failed", false},
		{3, 5, "failed", false},
		{4, 5, "dead", true}, // 4+1 == 5 → cap reached
		{5, 5, "dead", true},
	}
	for _, c := range cases {
		st, dead := nextFailureStatus(c.attempts, c.max)
		if st != c.wantStatus || dead != c.wantDead {
			t.Errorf("nextFailureStatus(%d,%d) = %q/%v, want %q/%v",
				c.attempts, c.max, st, dead, c.wantStatus, c.wantDead)
		}
	}
}

func TestSagaTargetKind(t *testing.T) {
	cases := []struct {
		engine, resource string
		wantKind         string
		wantErr          bool
	}{
		{"", "", "", false},
		{"mongodb", "", "", false}, // no resource → skip
		{"mongodb", "orders", "mongo", false},
		{"redis", "stream", "stream", false},
		{"neo4j", "graph", "stream", false},
		{"qdrant", "vecs", "stream", false},
		{"postgresql", "t", "", true}, // unsupported
	}
	for _, c := range cases {
		kind, err := sagaTargetKind(c.engine, c.resource)
		if kind != c.wantKind || (err != nil) != c.wantErr {
			t.Errorf("sagaTargetKind(%q,%q) = %q/%v, want %q/err=%v",
				c.engine, c.resource, kind, err, c.wantKind, c.wantErr)
		}
	}
}

// TestStreamFieldsOrder pins the exact positional XADD field order (stream
// consumers depend on it for parity with the Node relay).
func TestStreamFieldsOrder(t *testing.T) {
	e := &outboxEvent{
		ID: "e1", AggregateID: "agg1", EventType: "created",
		RequestID: "req1", ActorID: "act1", IdempotencyKey: "idem1",
	}
	got := streamFields(e, `{"x":1}`)
	want := []any{
		"id", "e1", "aggregate_id", "agg1", "event_type", "created",
		"payload", `{"x":1}`, "request_id", "req1", "actor_id", "act1",
		"idempotency_key", "idem1",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("streamFields = %v, want %v", got, want)
	}
}

func TestSagaStreamFieldsOrder(t *testing.T) {
	e := &outboxEvent{ID: "e1", AggregateID: "agg1", Op: "upsert", RequestID: "r", ActorID: "a", IdempotencyKey: "i"}
	got := sagaStreamFields(e, `{}`)
	want := []any{
		"id", "e1", "aggregate_id", "agg1", "op", "upsert", "payload", "{}",
		"request_id", "r", "actor_id", "a", "idempotency_key", "i",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("sagaStreamFields = %v, want %v", got, want)
	}
}

// TestRealtimeBody pins the realtime envelope: topic shape, idempotency
// fallback to id, and nil request/actor when empty.
func TestRealtimeBody(t *testing.T) {
	e := &outboxEvent{
		ID: "e1", Aggregate: "order", AggregateID: "o1", EventType: "placed",
		Payload: json.RawMessage(`{"total":9}`),
	}
	body := realtimeBody(e)
	if body["topic"] != "outbox/order/placed" {
		t.Errorf("topic = %v, want outbox/order/placed", body["topic"])
	}
	if body["idempotency_key"] != "e1" { // falls back to id when no idem key
		t.Errorf("idempotency_key = %v, want e1", body["idempotency_key"])
	}
	payload := body["payload"].(map[string]any)
	if payload["request_id"] != nil || payload["actor_id"] != nil {
		t.Errorf("empty request/actor must be nil, got %v/%v", payload["request_id"], payload["actor_id"])
	}
	data := payload["data"].(map[string]any)
	if data["total"] != float64(9) {
		t.Errorf("data not unwrapped: %v", data)
	}

	// with an explicit idempotency key it is used verbatim
	e.IdempotencyKey = "idem-9"
	if realtimeBody(e)["idempotency_key"] != "idem-9" {
		t.Errorf("explicit idempotency key must be preserved")
	}
}

func TestObjectJSONOnlyObjects(t *testing.T) {
	if objectJSON(json.RawMessage(`{"a":1}`)) == nil {
		t.Errorf("object compensation payload must be kept")
	}
	for _, raw := range []string{`[1]`, `5`, `null`, ``} {
		if objectJSON(json.RawMessage(raw)) != nil {
			t.Errorf("non-object %q must yield no compensation", raw)
		}
	}
}

func TestNoopProjectorIsSoftDependency(t *testing.T) {
	p := noopProjector{log: slog.Default()}
	if p.available() {
		t.Errorf("noop projector must report unavailable")
	}
	e := &outboxEvent{ID: "e1", Aggregate: "order"}
	// Both seams must succeed (nil) so a good pg write is never failed/compensated
	// merely because there is no mongo sink.
	if err := p.projectOrder(context.Background(), e); err != nil {
		t.Errorf("projectOrder must not fail when mongo unavailable: %v", err)
	}
	if err := p.dispatchMongo(context.Background(), e); err != nil {
		t.Errorf("dispatchMongo must not fail when mongo unavailable: %v", err)
	}
}

func TestPublishedDedupeKey(t *testing.T) {
	if publishedDedupeKey("abc") != "outbox-relay:published:abc" {
		t.Errorf("dedupe key shape changed")
	}
}

func TestNameAndConfigDefaults(t *testing.T) {
	s := New(slog.Default(), nil)
	if s.Name() != "outbox-relay" {
		t.Errorf("Name() = %q, want outbox-relay", s.Name())
	}
	if s.batchSize != 25 || s.maxAttempts != 5 {
		t.Errorf("defaults off: batch=%d maxAttempts=%d", s.batchSize, s.maxAttempts)
	}
	if s.project.available() { // default projector is the no-op (unavailable)
		t.Errorf("default projector should be the no-op")
	}
}
