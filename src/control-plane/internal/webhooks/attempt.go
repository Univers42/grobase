package webhooks

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

// handleEvent inserts pending delivery rows for every matching subscription,
// then triggers an immediate first attempt for each one.
func (d *Dispatcher) handleEvent(ctx context.Context, aggregate string, msg redis.XMessage) error {
	eventID, _ := msg.Values["id"].(string)
	eventType, _ := msg.Values["event_type"].(string)
	aggregateID, _ := msg.Values["aggregate_id"].(string)
	payloadStr, _ := msg.Values["payload"].(string)
	if eventID == "" || eventType == "" {
		return nil
	}

	// Outbox events are tenant-attributed via payload (tenant_id field) when
	// present; otherwise the event is broadcast to subscribers across all
	// tenants of the same aggregate. The dispatcher only delivers to subs
	// matching the event's tenant_id.
	var payload map[string]any
	if payloadStr != "" {
		_ = json.Unmarshal([]byte(payloadStr), &payload)
	}
	tenantID := stringFromPayload(payload, "tenant_id")

	subs, err := d.lookupMatching(ctx, tenantID, aggregate, eventType)
	if err != nil {
		return fmt.Errorf("lookup subscriptions: %w", err)
	}
	d.fanOut(ctx, subs, fanOutArgs{eventID, aggregate, aggregateID, eventType, payload})
	return nil
}

// fanOutArgs carries the resolved event fields to the per-subscription fan-out
// (keeps fanOut under the 4-parameter limit).
type fanOutArgs struct {
	eventID, aggregate, aggregateID, eventType string
	payload                                    map[string]any
}

func (d *Dispatcher) fanOut(ctx context.Context, subs []Subscription, a fanOutArgs) {
	for _, sub := range subs {
		if err := d.enqueueDelivery(ctx, sub, a); err != nil {
			d.log.Warn("enqueue delivery failed", "sub", sub.ID, "event", a.eventID, "err", err)
			continue
		}
		go d.attempt(context.Background(), sub.ID, a.eventID)
	}
}

func (d *Dispatcher) enqueueDelivery(ctx context.Context, sub Subscription, a fanOutArgs) error {
	body, _ := json.Marshal(a.payload)
	return d.db.TenantTx(ctx, sub.TenantID, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			INSERT INTO public.webhook_deliveries
			       (subscription_id, tenant_id, event_id, aggregate, event_type, payload, next_attempt_at)
			VALUES ($1::uuid, $2, $3, $4, $5, $6::jsonb, now())
			ON CONFLICT (subscription_id, event_id) DO NOTHING`,
			sub.ID, sub.TenantID, a.eventID, a.aggregate, a.eventType, string(body))
		return err
	})
}
