package outboxrelay

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"reflect"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/bson"
)

// fixedTime pins nowFn so the updated_at field is deterministic across the
// builder/dispatch assertions (the same role a frozen clock plays in the Node
// tests). Restored by every test via t.Cleanup.
var fixedTime = time.Date(2026, 6, 13, 12, 0, 0, 0, time.UTC)

func freezeNow(t *testing.T) {
	t.Helper()
	prev := nowFn
	nowFn = func() time.Time { return fixedTime }
	t.Cleanup(func() { nowFn = prev })
}

// fakeMongo records the operations the projector would issue so the upsert /
// delete routing and the constructed documents can be asserted without a live
// Mongo (mirrors how the package fakes its seams).
type fakeMongo struct {
	ops    []fakeOp
	failOn string // collection name to fail on (to exercise error wrapping)
}

type fakeOp struct {
	kind   string // "update" | "delete"
	coll   string
	filter any
	update any
	upsert bool
}

func (f *fakeMongo) updateOne(_ context.Context, coll string, filter, update any, upsert bool) error {
	f.ops = append(f.ops, fakeOp{kind: "update", coll: coll, filter: filter, update: update, upsert: upsert})
	if coll == f.failOn {
		return errors.New("boom")
	}
	return nil
}

func (f *fakeMongo) deleteOne(_ context.Context, coll string, filter any) error {
	f.ops = append(f.ops, fakeOp{kind: "delete", coll: coll, filter: filter})
	if coll == f.failOn {
		return errors.New("boom")
	}
	return nil
}

func newFakeProjector(f *fakeMongo) *mongoProjector {
	return &mongoProjector{db: f}
}

// TestOrderProjection pins the orders_view upsert filter+update exactly (parity
// with OutboxRelayService.project): payload merged minus its own _id, then the
// canonical _id/aggregate_id/last_event_type/outbox_event_id/updated_at stamps.
func TestOrderProjection(t *testing.T) {
	freezeNow(t)
	e := &outboxEvent{
		ID:          "evt-1",
		Aggregate:   "order",
		AggregateID: "ord-9",
		EventType:   "order.placed",
		// payload carries an _id that MUST be stripped, plus real fields.
		Payload: json.RawMessage(`{"_id":"SHOULD_BE_DROPPED","total":42,"sku":"abc"}`),
	}
	filter, update := orderProjection(e)

	if !reflect.DeepEqual(filter, bson.M{"_id": "ord-9"}) {
		t.Fatalf("filter = %#v, want {_id: ord-9}", filter)
	}
	want := bson.M{"$set": bson.M{
		"total":           float64(42),
		"sku":             "abc",
		"_id":             "ord-9",
		"aggregate_id":    "ord-9",
		"last_event_type": "order.placed",
		"outbox_event_id": "evt-1",
		"updated_at":      fixedTime,
	}}
	if !reflect.DeepEqual(update, want) {
		t.Fatalf("update = %#v\nwant %#v", update, want)
	}
}

// TestOrderProjectionNonObjectPayload pins the {value: ...} wrapping path: a
// non-object payload becomes a single `value` field, never crashing the upsert.
func TestOrderProjectionNonObjectPayload(t *testing.T) {
	freezeNow(t)
	e := &outboxEvent{ID: "e", Aggregate: "order", AggregateID: "o1", EventType: "x", Payload: json.RawMessage(`[1,2]`)}
	_, update := orderProjection(e)
	set := update["$set"].(bson.M)
	if !reflect.DeepEqual(set["value"], []any{float64(1), float64(2)}) {
		t.Fatalf("array payload must be wrapped under value, got %#v", set["value"])
	}
	if set["_id"] != "o1" {
		t.Fatalf("_id must be the aggregate id, got %v", set["_id"])
	}
}

// TestSagaProjectionUnwrapsData pins the saga upsert: payload.data (when an
// object) is the body, plus aggregate_id/outbox_event_id/request_id/updated_at.
func TestSagaProjectionUnwrapsData(t *testing.T) {
	freezeNow(t)
	e := &outboxEvent{
		ID:          "evt-7",
		Aggregate:   "inventory",
		AggregateID: "inv-3",
		RequestID:   "req-42",
		Payload:     json.RawMessage(`{"data":{"qty":5,"loc":"A"},"meta":"ignored"}`),
	}
	filter, update := sagaProjection(e)
	if !reflect.DeepEqual(filter, bson.M{"_id": "inv-3"}) {
		t.Fatalf("filter = %#v, want {_id: inv-3}", filter)
	}
	want := bson.M{"$set": bson.M{
		"qty":             float64(5),
		"loc":             "A",
		"aggregate_id":    "inv-3",
		"outbox_event_id": "evt-7",
		"request_id":      "req-42",
		"updated_at":      fixedTime,
	}}
	if !reflect.DeepEqual(update, want) {
		t.Fatalf("update = %#v\nwant %#v", update, want)
	}
}

// TestSagaProjectionFallsBackToPayload pins the `?? payload` branch: when
// payload has no object `data`, the whole payload object is the body, and an
// empty request_id is written as BSON null (package null/empty convention).
func TestSagaProjectionFallsBackToPayload(t *testing.T) {
	freezeNow(t)
	e := &outboxEvent{
		ID:          "evt-8",
		AggregateID: "x-1",
		// no `data` key → fall back to the payload object itself
		Payload: json.RawMessage(`{"name":"widget"}`),
	}
	_, update := sagaProjection(e)
	set := update["$set"].(bson.M)
	if set["name"] != "widget" {
		t.Fatalf("payload body not used as fallback: %#v", set)
	}
	if set["request_id"] != nil {
		t.Fatalf("empty request_id must be BSON null, got %#v", set["request_id"])
	}
}

// TestSagaDataNonObjectDataKey ensures a non-object `data` (e.g. a scalar) does
// NOT unwrap — the whole payload is used (parity with objectPayload(data) ?? payload).
func TestSagaDataNonObjectDataKey(t *testing.T) {
	got := sagaData(json.RawMessage(`{"data":7,"k":"v"}`))
	want := map[string]any{"data": float64(7), "k": "v"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sagaData scalar-data = %#v, want %#v", got, want)
	}
}

// TestDispatchMongoRouting drives dispatchMongo through the fake and asserts the
// op kind, target collection, and filter for each saga shape.
func TestDispatchMongoRouting(t *testing.T) {
	freezeNow(t)
	cases := []struct {
		name      string
		event     *outboxEvent
		wantKind  string
		wantColl  string
		wantNoOp  bool // payload not an object → no operation issued
	}{
		{
			name:     "upsert_target_resource",
			event:    &outboxEvent{ID: "e1", Aggregate: "agg", AggregateID: "a1", TargetResource: "orders_proj", Op: "upsert", Payload: json.RawMessage(`{"x":1}`)},
			wantKind: "update", wantColl: "orders_proj",
		},
		{
			name:     "delete_by_id",
			event:    &outboxEvent{ID: "e2", Aggregate: "agg", AggregateID: "a2", TargetResource: "orders_proj", Op: "delete", Payload: json.RawMessage(`{"x":1}`)},
			wantKind: "delete", wantColl: "orders_proj",
		},
		{
			name:     "collection_falls_back_to_aggregate",
			event:    &outboxEvent{ID: "e3", Aggregate: "fallback_agg", AggregateID: "a3", Op: "upsert", Payload: json.RawMessage(`{"x":1}`)},
			wantKind: "update", wantColl: "fallback_agg",
		},
		{
			name:    "non_object_payload_skips",
			event:   &outboxEvent{ID: "e4", AggregateID: "a4", TargetResource: "c", Op: "upsert", Payload: json.RawMessage(`5`)},
			wantNoOp: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeMongo{}
			p := newFakeProjector(f)
			if err := p.dispatchMongo(context.Background(), c.event); err != nil {
				t.Fatalf("dispatchMongo error: %v", err)
			}
			if c.wantNoOp {
				if len(f.ops) != 0 {
					t.Fatalf("expected no op for non-object payload, got %#v", f.ops)
				}
				return
			}
			if len(f.ops) != 1 {
				t.Fatalf("expected exactly 1 op, got %d (%#v)", len(f.ops), f.ops)
			}
			op := f.ops[0]
			if op.kind != c.wantKind || op.coll != c.wantColl {
				t.Fatalf("op = %s/%s, want %s/%s", op.kind, op.coll, c.wantKind, c.wantColl)
			}
			wantFilter := bson.M{"_id": c.event.AggregateID}
			if !reflect.DeepEqual(op.filter, wantFilter) {
				t.Fatalf("filter = %#v, want %#v", op.filter, wantFilter)
			}
			if op.kind == "update" && !op.upsert {
				t.Fatalf("saga upsert must set upsert=true")
			}
		})
	}
}

// TestProjectOrderIssuesUpsert confirms projectOrder targets orders_view with
// upsert=true and wraps errors.
func TestProjectOrderIssuesUpsert(t *testing.T) {
	freezeNow(t)
	f := &fakeMongo{}
	p := newFakeProjector(f)
	e := &outboxEvent{ID: "e", Aggregate: "order", AggregateID: "o", EventType: "placed", Payload: json.RawMessage(`{"a":1}`)}
	if err := p.projectOrder(context.Background(), e); err != nil {
		t.Fatalf("projectOrder error: %v", err)
	}
	if len(f.ops) != 1 || f.ops[0].coll != ordersViewCollection || !f.ops[0].upsert {
		t.Fatalf("projectOrder must upsert orders_view, got %#v", f.ops)
	}

	// Error path: a driver failure surfaces (so process() → markFailed can act).
	fFail := &fakeMongo{failOn: ordersViewCollection}
	if err := newFakeProjector(fFail).projectOrder(context.Background(), e); err == nil {
		t.Fatalf("projectOrder must return the driver error")
	}
}

// TestAvailableContract: a projector with a live seam reports available; a nil
// or seam-less one does not (so the relay's order/saga branches stay gated).
func TestAvailableContract(t *testing.T) {
	if (&mongoProjector{db: &fakeMongo{}}).available() != true {
		t.Fatalf("connected projector must report available")
	}
	if (&mongoProjector{}).available() != false {
		t.Fatalf("seam-less projector must report unavailable")
	}
	var nilProjector *mongoProjector
	if nilProjector.available() != false {
		t.Fatalf("nil projector must report unavailable")
	}
}

// TestNewMongoProjectorEmptyURIDegrades: no URI → no projector (degraded), never
// a panic — the soft-dependency boot path.
func TestNewMongoProjectorEmptyURI(t *testing.T) {
	p, ok := newMongoProjector(context.Background(), slog.Default(), "")
	if ok || p != nil {
		t.Fatalf("empty OUTBOX_MONGO_URL must yield no projector, got ok=%v p=%v", ok, p)
	}
}
