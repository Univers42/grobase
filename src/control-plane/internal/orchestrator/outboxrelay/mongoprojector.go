package outboxrelay

import (
	"context"
	"log/slog"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
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
	dbName := config.EnvStr("MONGO_DB_NAME", "mini_baas")
	client, ok := connectMongo(ctx, log, uri)
	if !ok {
		return nil, false
	}
	db := client.Database(dbName)
	ensureOrdersViewIndex(ctx, log, db)
	log.Info("mongo projector connected", "db", dbName)
	return &mongoProjector{log: log, client: client, db: driverDB{db: db}}, true
}

// connectMongo dials and pings OUTBOX_MONGO_URL with the Node MongoService 5s
// ceiling so a missing mongo degrades quickly. ok=false (already logged) keeps
// the caller in degraded mode instead of failing to boot.
func connectMongo(ctx context.Context, log *slog.Logger, uri string) (*mongo.Client, bool) {
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
	return client, true
}

// ensureOrdersViewIndex creates the orders_view aggregate_id index (parity with
// onModuleInit). A failure is non-fatal (the projection still works) — log and
// continue, matching the soft-dependency posture.
func ensureOrdersViewIndex(ctx context.Context, log *slog.Logger, db *mongo.Database) {
	idxCtx, idxCancel := context.WithTimeout(ctx, 5*time.Second)
	defer idxCancel()
	if _, err := db.Collection(ordersViewCollection).Indexes().CreateOne(idxCtx, mongo.IndexModel{
		Keys: bson.D{{Key: "aggregate_id", Value: 1}},
	}); err != nil {
		log.Warn("orders_view index ensure failed (continuing)", "err", err)
	}
}
