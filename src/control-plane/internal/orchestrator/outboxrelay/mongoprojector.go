package outboxrelay

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// ordersViewCollection is the read-projection collection the relay maintains for
// `order` aggregates (parity with OutboxRelayService.project's
// `collection<OrderProjection>('orders_view')`).
const ordersViewCollection = "orders_view"

// mongoClient is the narrow slice of the driver the projector needs. It exists
// so the doc/op builders can be unit-tested without a live Mongo (the existing
// package style: pure helpers tested directly, thin methods over the driver).
type mongoClient interface {
	updateOne(ctx context.Context, coll string, filter, update any, upsert bool) error
	deleteOne(ctx context.Context, coll string, filter any) error
}

// mongoProjector is the driver-backed Mongo read-projection sink. It mirrors the
// Node OutboxRelayService.project (orders_view) and SagaCoordinatorService
// .dispatchMongo (saga mongodb-target) byte-for-byte: same collections, same
// `_id`/owner-stamp keys, same upsert semantics, same delete-by-`_id`.
//
// Mongo is a SOFT dependency (OUTBOX_MONGO_URL is optional): a connect failure
// degrades to noopProjector behavior at construction time, never crashing the
// relay. Once connected, errors from a projection ARE returned — the relay's
// saga logic decides compensation, exactly as the Node service throws and lets
// process() → markFailed handle it.
type mongoProjector struct {
	log    *slog.Logger
	client *mongo.Client
	db     mongoClient
}

// newMongoProjector connects to OUTBOX_MONGO_URL and resolves the database name
// the SAME way the Node MongoService does: from MONGO_DB_NAME (default
// "mini_baas"), NOT the connection-string path (the Node driver calls
// client.db(dbName) and ignores the URI path; the Go driver requires an explicit
// name, so reproducing the env resolution is what keeps the target database
// identical). It also creates the orders_view { aggregate_id: 1 } index, the
// same one-time index onModuleInit builds.
//
// A connect (or ping) failure returns ok=false so the caller keeps the no-op
// projector — degraded mode, projections disabled — instead of failing to boot.
func newMongoProjector(ctx context.Context, log *slog.Logger, uri string) (*mongoProjector, bool) {
	if uri == "" {
		return nil, false
	}
	dbName := env("MONGO_DB_NAME", "mini_baas")

	// serverSelectionTimeout mirrors the Node MongoService 5s ceiling so a missing
	// mongo degrades quickly instead of hanging the relay's first tick.
	connectCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	client, err := mongo.Connect(connectCtx, options.Client().
		ApplyURI(uri).
		SetServerSelectionTimeout(5*time.Second))
	if err != nil {
		log.Warn("mongo projector unavailable — degraded mode, projections disabled (OUTBOX_MONGO_URL)",
			"err", err)
		return nil, false
	}
	if err := client.Ping(connectCtx, nil); err != nil {
		log.Warn("mongo projector unavailable — degraded mode, projections disabled (OUTBOX_MONGO_URL)",
			"err", err)
		_ = client.Disconnect(context.Background())
		return nil, false
	}

	db := client.Database(dbName)
	p := &mongoProjector{log: log, client: client, db: driverDB{db: db}}

	// Parity with onModuleInit: ensure the orders_view aggregate_id index exists.
	// A failure here is non-fatal (the projection still works), matching the
	// soft-dependency posture; log and continue.
	idxCtx, idxCancel := context.WithTimeout(ctx, 5*time.Second)
	defer idxCancel()
	if _, err := db.Collection(ordersViewCollection).Indexes().CreateOne(idxCtx, mongo.IndexModel{
		Keys: bson.D{{Key: "aggregate_id", Value: 1}},
	}); err != nil {
		log.Warn("orders_view index ensure failed (continuing)", "err", err)
	}

	log.Info("mongo projector connected", "db", dbName)
	return p, true
}

func (m *mongoProjector) available() bool { return m != nil && m.db != nil }

// projectOrder upserts the orders_view projection for an `order` aggregate —
// the Go port of OutboxRelayService.project.
func (m *mongoProjector) projectOrder(ctx context.Context, e *outboxEvent) error {
	filter, update := orderProjection(e)
	if err := m.db.updateOne(ctx, ordersViewCollection, filter, update, true); err != nil {
		return fmt.Errorf("orders_view upsert: %w", err)
	}
	return nil
}

// dispatchMongo applies a saga mongodb-target event (upsert/delete) — the Go
// port of SagaCoordinatorService.dispatchMongo.
func (m *mongoProjector) dispatchMongo(ctx context.Context, e *outboxEvent) error {
	coll := e.TargetResource
	if coll == "" {
		coll = e.Aggregate
	}
	// objectPayload guard: a non-object saga payload yields no projection (parity
	// with `const payload = this.objectPayload(event.payload); if (!payload) return;`).
	if objectJSON(e.Payload) == nil {
		return nil
	}
	if e.Op == "delete" {
		if err := m.db.deleteOne(ctx, coll, bson.M{"_id": e.AggregateID}); err != nil {
			return fmt.Errorf("mongo dispatch delete %s: %w", coll, err)
		}
		return nil
	}
	filter, update := sagaProjection(e)
	if err := m.db.updateOne(ctx, coll, filter, update, true); err != nil {
		return fmt.Errorf("mongo dispatch upsert %s: %w", coll, err)
	}
	return nil
}

// close disconnects the client (called on relay shutdown).
func (m *mongoProjector) close(ctx context.Context) {
	if m != nil && m.client != nil {
		_ = m.client.Disconnect(ctx)
	}
}

/* ─────── pure document/op builders (unit-tested without a live mongo) ─────── */

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
func orderProjection(e *outboxEvent) (bson.M, bson.M) {
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
	set["updated_at"] = nowFn()
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
func sagaProjection(e *outboxEvent) (bson.M, bson.M) {
	data := sagaData(e.Payload)
	set := bson.M{}
	for k, v := range data {
		set[k] = bsonValue(v)
	}
	set["aggregate_id"] = e.AggregateID
	set["outbox_event_id"] = e.ID
	set["request_id"] = nullableValue(e.RequestID)
	set["updated_at"] = nowFn()
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

// asObject returns v as a map only when it is a JSON object (not an array /
// scalar / nil) — the Go mirror of objectPayload applied to an already-decoded
// value.
func asObject(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return nil
}

// nullableValue maps "" → nil so an absent request_id is written as BSON null
// (parity with the Node `request_id: event.request_id` when null), consistent
// with realtimeBody and saga.go's nullable().
func nullableValue(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// bsonValue passes JSON-decoded values through. json.Unmarshal already yields
// driver-friendly Go types (map[string]any, []any, float64, string, bool, nil),
// so no conversion is needed; the indirection is a single seam for any future
// type coercion and keeps the builders readable.
func bsonValue(v any) any { return v }

// nowFn is the projection timestamp source (overridable in tests for
// determinism, the same role `new Date()` plays in the Node upsert $set).
var nowFn = func() time.Time { return time.Now().UTC() }

/* ─────── driver adapter ─────── */

// driverDB adapts a *mongo.Database to the narrow mongoClient seam.
type driverDB struct{ db *mongo.Database }

func (d driverDB) updateOne(ctx context.Context, coll string, filter, update any, upsert bool) error {
	_, err := d.db.Collection(coll).UpdateOne(ctx, filter, update, options.Update().SetUpsert(upsert))
	return err
}

func (d driverDB) deleteOne(ctx context.Context, coll string, filter any) error {
	_, err := d.db.Collection(coll).DeleteOne(ctx, filter)
	return err
}
