package functriggers

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

// event holds the fields decoded from one outbox stream message.
type event struct {
	eventID     string
	eventType   string
	aggregateID string
	tenantID    string
	payload     map[string]any
}

// decodeEvent reads the stream message values into an event. A missing id or
// event_type yields ok=false (the message is skipped, not an error).
func decodeEvent(msg redis.XMessage) (event, bool) {
	var ev event
	ev.eventID, _ = msg.Values["id"].(string)
	ev.eventType, _ = msg.Values["event_type"].(string)
	ev.aggregateID, _ = msg.Values["aggregate_id"].(string)
	payloadStr, _ := msg.Values["payload"].(string)
	if ev.eventID == "" || ev.eventType == "" {
		return event{}, false
	}
	if payloadStr != "" {
		_ = json.Unmarshal([]byte(payloadStr), &ev.payload)
	}
	ev.tenantID = stringFromPayload(ev.payload, "tenant_id")
	return ev, true
}

// handleEvent inserts pending delivery rows for every matching trigger, then
// triggers an immediate first invoke for each one.
func (d *Dispatcher) handleEvent(ctx context.Context, aggregate string, msg redis.XMessage) error {
	ev, ok := decodeEvent(msg)
	if !ok {
		return nil
	}
	triggers, err := d.lookupMatching(ctx, ev.tenantID, aggregate, ev.eventType)
	if err != nil {
		return fmt.Errorf("lookup triggers: %w", err)
	}
	for _, tr := range triggers {
		dl := delivery{tr: tr, eventID: ev.eventID, aggregate: aggregate, eventType: ev.eventType, payload: ev.payload}
		if err := d.enqueueDelivery(ctx, dl); err != nil {
			d.log.Warn("enqueue delivery failed", "trigger", tr.ID, "event", ev.eventID, "err", err)
			continue
		}
		go d.attempt(context.Background(), tr.ID, ev.eventID)
	}
	return nil
}

// lookupMatching reads the enabled trigger set for the tenant and filters
// in-Go (same approach as webhooks).
//
// The `tenant_id = $1` predicate is the AUTHORITATIVE tenant scope: this
// dispatcher connects to the system Postgres as the table-owning `postgres`
// superuser, so the per-tenant RLS policy on function_triggers is silently
// bypassed (owner + ENABLE-not-FORCE). Relying on TenantTx's GUC alone would
// return EVERY tenant's enabled triggers and fire them on this event — a
// cross-tenant compute + data-exfiltration breach. We scope explicitly in SQL
// and never depend on RLS being enforced here.
func (d *Dispatcher) lookupMatching(ctx context.Context, tenantID, aggregate, eventType string) ([]Trigger, error) {
	if tenantID == "" {
		return nil, nil
	}
	triggers := make([]Trigger, 0)
	err := d.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, tenant_id, name, function_name, event_types, aggregates,
			       enabled, max_attempts, timeout_ms, created_at::text, updated_at::text
			  FROM public.function_triggers
			 WHERE enabled = true AND tenant_id = $1`, tenantID)
		if err != nil {
			return err
		}
		defer rows.Close()
		return collectMatching(rows, aggregate, eventType, &triggers)
	})
	return triggers, err
}

// collectMatching scans every row and appends the triggers that fire for this
// (aggregate, eventType).
func collectMatching(rows pgx.Rows, aggregate, eventType string, out *[]Trigger) error {
	for rows.Next() {
		var tr Trigger
		if err := scanTrigger(rows, &tr); err != nil {
			return err
		}
		if tr.matches(aggregate, eventType) {
			*out = append(*out, tr)
		}
	}
	return rows.Err()
}

// delivery groups the columns inserted for one pending function delivery.
type delivery struct {
	tr        Trigger
	eventID   string
	aggregate string
	eventType string
	payload   map[string]any
}

func (d *Dispatcher) enqueueDelivery(ctx context.Context, dl delivery) error {
	body, _ := json.Marshal(dl.payload)
	return d.db.TenantTx(ctx, dl.tr.TenantID, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			INSERT INTO public.function_deliveries
			       (trigger_id, tenant_id, function_name, event_id, aggregate, event_type, payload, next_attempt_at)
			VALUES ($1::uuid, $2, $3, $4, $5, $6, $7::jsonb, now())
			ON CONFLICT (trigger_id, event_id) DO NOTHING`,
			dl.tr.ID, dl.tr.TenantID, dl.tr.FunctionName, dl.eventID, dl.aggregate, dl.eventType, string(body))
		return err
	})
}
