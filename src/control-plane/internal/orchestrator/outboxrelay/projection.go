package outboxrelay

import (
	"encoding/json"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"go.mongodb.org/mongo-driver/bson"
)

// projectorNow is the projection timestamp source. It lives on the projector
// (overridable in tests for determinism, the same role `new Date()` plays in the
// Node upsert $set); nil falls back to time.Now().UTC for the zero-value case.
func (m *mongoProjector) projectorNow() time.Time {
	if m == nil || m.now == nil {
		return time.Now().UTC()
	}
	return m.now()
}

// orderProjection builds the (filter, update) pair for the orders_view upsert,
// exactly reproducing OutboxRelayService.project:
//
//	filter: { _id: aggregate_id }
//	update: { $set: { ...payload (minus _id), _id, aggregate_id,
//	                   last_event_type, outbox_event_id, updated_at } }
//
// payload is payloadObject(event) (object as-is, else {value: ...}); its own
// `_id` is stripped first (the Node `delete payload['_id']`) so the canonical
// `_id` is always the aggregate id and never overwritten by the payload.
func (m *mongoProjector) orderProjection(e *outboxEvent) (bson.M, bson.M) {
	set := bson.M{}
	for k, v := range payloadObject(e.Payload) {
		if k == "_id" {
			continue
		}
		set[k] = bsonValue(v)
	}
	set["_id"] = e.AggregateID
	set["aggregate_id"] = e.AggregateID
	set["last_event_type"] = e.EventType
	set["outbox_event_id"] = e.ID
	set["updated_at"] = m.projectorNow()
	return bson.M{"_id": e.AggregateID}, bson.M{"$set": set}
}

// sagaProjection builds the (filter, update) pair for the saga mongodb upsert,
// reproducing SagaCoordinatorService.dispatchMongo's non-delete branch:
//
//	data   = objectPayload(payload['data']) ?? payload
//	filter: { _id: aggregate_id }
//	update: { $set: { ...data, aggregate_id, outbox_event_id, request_id, updated_at } }
//
// request_id follows the package's established null/empty convention (see
// realtimeBody / nullable in saga.go): the Go event flattens a DB-null
// request_id to "", and we map "" back to a BSON null so the document shape
// matches the dominant Node case where request_id is absent (null).
func (m *mongoProjector) sagaProjection(e *outboxEvent) (bson.M, bson.M) {
	data := sagaData(e.Payload)
	set := bson.M{}
	for k, v := range data {
		set[k] = bsonValue(v)
	}
	set["aggregate_id"] = e.AggregateID
	set["outbox_event_id"] = e.ID
	set["request_id"] = pg.NullableStr(e.RequestID) // "" -> BSON null (parity with Node request_id)
	set["updated_at"] = m.projectorNow()
	return bson.M{"_id": e.AggregateID}, bson.M{"$set": set}
}

// sagaData extracts the projected document body: payload.data when it is itself
// a JSON object, else the payload object (parity with
// `this.objectPayload(payload['data']) ?? payload`). The caller has already
// guaranteed payload is an object (objectJSON != nil).
func sagaData(raw json.RawMessage) map[string]any {
	payload := payloadObject(raw)
	if inner, ok := payload["data"]; ok {
		if m := asObject(inner); m != nil {
			return m
		}
	}
	return payload
}
