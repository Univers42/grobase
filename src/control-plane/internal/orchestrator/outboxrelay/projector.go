package outboxrelay

import (
	"context"
	"fmt"
	"log/slog"
)

// errUnsupportedEngine mirrors the Node "Unsupported saga target engine" throw.
func errUnsupportedEngine(engine string) error {
	return fmt.Errorf("unsupported saga target engine: %s", engine)
}

// projector is the Mongo read-projection seam. The default is the no-op (Mongo
// unavailable); a real driver-backed projector is a follow-up slice. Both the
// orders_view projection and the saga mongodb-target dispatch route through it.
type projector interface {
	available() bool
	// projectOrder upserts the orders_view projection for an `order` aggregate.
	projectOrder(ctx context.Context, e *outboxEvent) error
	// dispatchMongo applies a saga mongodb-target event (upsert/delete).
	dispatchMongo(ctx context.Context, e *outboxEvent) error
}

// noopProjector is the Mongo-unavailable behavior: skip loudly, never fail (so a
// good pg write is not marked failed → compensated just because there is no
// projection sink), exactly as the Node service does when isAvailable is false.
type noopProjector struct{ log *slog.Logger }

func (n noopProjector) available() bool { return false }

func (n noopProjector) projectOrder(_ context.Context, e *outboxEvent) error {
	n.log.Warn("orders_view projection skipped (mongo unavailable)", "event", e.ID)
	return nil
}

func (n noopProjector) dispatchMongo(_ context.Context, e *outboxEvent) error {
	resource := e.TargetResource
	if resource == "" {
		resource = e.Aggregate
	}
	n.log.Warn("mongo projection skipped (mongo unavailable)", "event", e.ID, "resource", resource)
	return nil
}
