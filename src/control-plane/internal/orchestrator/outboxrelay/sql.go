package outboxrelay

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

const sagaSelectCols = `target_engine, target_resource, op, compensation_payload, idempotency_key`
const sagaNullCols = `NULL::text AS target_engine, NULL::text AS target_resource, NULL::text AS op, ` +
	`NULL::jsonb AS compensation_payload, NULL::text AS idempotency_key`

// hasSagaColumns reports whether the saga columns exist (the table predates the
// saga migration on some deployments) — exactly the Node 6-column probe.
func hasSagaColumns(ctx context.Context, tx pgx.Tx) (bool, error) {
	var count int
	err := tx.QueryRow(ctx,
		`SELECT COUNT(*) FROM information_schema.columns
		  WHERE table_schema='public' AND table_name='outbox_events'
		    AND column_name IN ('target_engine','target_resource','op','compensation_payload','idempotency_key','saga_state')`,
	).Scan(&count)
	return count == 6, err
}

// lockEvent selects+locks one relayable event. ok=false means it was already
// taken/published (skip-locked or status moved).
func lockEvent(ctx context.Context, tx pgx.Tx, id string, maxAttempts int, sagaCols bool) (*outboxEvent, bool, error) {
	cols := sagaNullCols
	if sagaCols {
		cols = sagaSelectCols
	}
	row := tx.QueryRow(ctx,
		`SELECT id::text, aggregate, aggregate_id, event_type, payload, request_id::text, actor_id::text, attempts, `+cols+`
		   FROM public.outbox_events
		  WHERE id = $1 AND status IN ('pending','failed') AND attempts < $2
		  FOR UPDATE SKIP LOCKED`, id, maxAttempts)
	return scanLockedEvent(row)
}

// scanLockedEvent maps one locked row into an outboxEvent, flattening the
// nullable text columns to "" (parity with the Node `?? ”` coalescing).
func scanLockedEvent(row pgx.Row) (*outboxEvent, bool, error) {
	var e outboxEvent
	var reqID, actorID, targetEngine, targetResource, op, idem *string
	var comp []byte
	err := row.Scan(&e.ID, &e.Aggregate, &e.AggregateID, &e.EventType, &e.Payload,
		&reqID, &actorID, &e.Attempts, &targetEngine, &targetResource, &op, &comp, &idem)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	e.RequestID = pg.DerefStr(reqID)
	e.ActorID = pg.DerefStr(actorID)
	e.TargetEngine = pg.DerefStr(targetEngine)
	e.TargetResource = pg.DerefStr(targetResource)
	e.Op = pg.DerefStr(op)
	e.IdempotencyKey = pg.DerefStr(idem)
	e.CompensationPayload = comp
	return &e, true, nil
}
