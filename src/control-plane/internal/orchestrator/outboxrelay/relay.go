package outboxrelay

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"

	"github.com/jackc/pgx/v5"
	redis "github.com/redis/go-redis/v9"
)

// tick drains one batch: select candidate ids, refresh the lag gauge, then
// process each. Errors are logged, never fatal (the next tick retries).
func (s *Service) tick(ctx context.Context) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id::text AS id
		   FROM public.outbox_events
		  WHERE status IN ('pending','failed') AND attempts < $1
		  ORDER BY created_at ASC, id ASC
		  LIMIT $2`, s.maxAttempts, s.batchSize)
	if err != nil {
		s.log.Warn("outbox relay tick failed", "err", err)
		return
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			s.log.Warn("outbox relay scan failed", "err", err)
			return
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		s.log.Warn("outbox relay rows error", "err", err)
		return
	}
	s.updateLag(ctx)
	for _, id := range ids {
		s.process(ctx, id)
	}
}

// process locks one event FOR UPDATE SKIP LOCKED inside a transaction, relays it,
// and commits the new status — mirroring OutboxRelayService.process.
func (s *Service) process(ctx context.Context, id string) {
	conn, err := s.pg.AcquireConn(ctx)
	if err != nil {
		s.log.Warn("outbox acquire conn failed", "err", err)
		return
	}
	defer conn.Release()

	tx, err := conn.Begin(ctx)
	if err != nil {
		s.log.Warn("outbox begin failed", "err", err)
		return
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	sagaCols, err := hasSagaColumns(ctx, tx)
	if err != nil {
		s.log.Warn("outbox saga-column probe failed", "id", id, "err", err)
		return
	}
	event, ok, err := lockEvent(ctx, tx, id, s.maxAttempts, sagaCols)
	if err != nil {
		s.log.Warn("outbox lock failed", "id", id, "err", err)
		return
	}
	if !ok {
		if err := tx.Commit(ctx); err == nil {
			committed = true
		}
		return
	}

	if relayErr := s.relay(ctx, event); relayErr != nil {
		if err := s.markFailed(ctx, tx, event, relayErr, sagaCols); err != nil {
			s.log.Warn("outbox markFailed failed", "id", id, "err", err)
			return
		}
	} else if err := markPublished(ctx, tx, event.ID, sagaCols); err != nil {
		s.log.Warn("outbox markPublished failed", "id", id, "err", err)
		return
	}

	if err := tx.Commit(ctx); err != nil {
		s.log.Warn("outbox commit failed", "id", id, "err", err)
		return
	}
	committed = true
}

// relay runs the publish + project + saga dispatch for a locked event. Any error
// surfaces to process → markFailed (parity with the Node inner try/catch).
func (s *Service) relay(ctx context.Context, e *outboxEvent) error {
	if err := s.publish(ctx, e); err != nil {
		return err
	}
	if e.Aggregate == "order" {
		if err := s.project.projectOrder(ctx, e); err != nil {
			return err
		}
	}
	return s.sagaDispatch(ctx, e)
}

// publish writes the event to its `outbox.<aggregate>` stream (idempotent via a
// Redis dedupe key) and best-effort fans it out to realtime.
func (s *Service) publish(ctx context.Context, e *outboxEvent) error {
	key := publishedDedupeKey(e.ID)
	if v, err := s.rdb.Get(ctx, key).Result(); err == nil && v != "" {
		return nil // already published
	} else if err != nil && !errors.Is(err, redis.Nil) {
		return err
	}
	payloadJSON, err := json.Marshal(payloadObject(e.Payload))
	if err != nil {
		return err
	}
	if err := s.rdb.XAdd(ctx, &redis.XAddArgs{
		Stream: "outbox." + e.Aggregate,
		Values: streamFields(e, string(payloadJSON)),
	}).Err(); err != nil {
		return err
	}
	if err := s.rdb.Set(ctx, key, "1", s.dedupeTTL).Err(); err != nil {
		return err
	}
	if err := s.publishRealtime(ctx, e); err != nil {
		s.log.Warn("realtime fan-out skipped", "event", e.ID, "err", err)
	}
	return nil
}

// publishRealtime POSTs the realtime envelope with a bounded timeout. A missing
// URL is a no-op (parity); a non-2xx is an error the caller logs (best-effort).
func (s *Service) publishRealtime(ctx context.Context, e *outboxEvent) error {
	if s.realtimeURL == "" {
		return nil
	}
	rctx, cancel := context.WithTimeout(ctx, s.realtimeWait)
	defer cancel()
	body, err := json.Marshal(realtimeBody(e))
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(rctx, http.MethodPost, s.realtimeURL, strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return errors.New("realtime publish " + resp.Status)
	}
	return nil
}

// updateLag refreshes the pending-events gauge (logged; see Service.pending).
func (s *Service) updateLag(ctx context.Context) {
	var count int64
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT COUNT(*) FROM public.outbox_events WHERE status IN ('pending','failed') AND attempts < $1`,
		s.maxAttempts)
	if err != nil {
		return
	}
	defer rows.Close()
	if rows.Next() {
		_ = rows.Scan(&count)
	}
	atomic.StoreInt64(&s.pending, count)
}

/* ─────── SQL helpers (operate on the active tx) ─────── */

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
	e.RequestID = deref(reqID)
	e.ActorID = deref(actorID)
	e.TargetEngine = deref(targetEngine)
	e.TargetResource = deref(targetResource)
	e.Op = deref(op)
	e.IdempotencyKey = deref(idem)
	e.CompensationPayload = comp
	return &e, true, nil
}

func markPublished(ctx context.Context, tx pgx.Tx, id string, sagaCols bool) error {
	if sagaCols {
		_, err := tx.Exec(ctx,
			`UPDATE public.outbox_events
			    SET status='published', saga_state='dispatched', published_at=now(), last_error=NULL
			  WHERE id=$1`, id)
		return err
	}
	_, err := tx.Exec(ctx,
		`UPDATE public.outbox_events SET status='published', published_at=now(), last_error=NULL WHERE id=$1`, id)
	return err
}

// markFailed bumps attempts and flips to failed/dead; on dead it counts the
// event and schedules a compensation (parity with markFailed).
func (s *Service) markFailed(ctx context.Context, tx pgx.Tx, e *outboxEvent, cause error, sagaCols bool) error {
	status, dead := nextFailureStatus(e.Attempts, s.maxAttempts)
	nextAttempts := e.Attempts + 1
	if dead {
		atomic.AddInt64(&s.dead, 1)
		if err := s.sagaCompensate(ctx, tx, e); err != nil {
			return err
		}
	}
	msg := cause.Error()
	if len(msg) > 2000 {
		msg = msg[:2000]
	}
	if sagaCols {
		_, err := tx.Exec(ctx,
			`UPDATE public.outbox_events
			    SET status=$2, saga_state = CASE WHEN $2='dead' THEN 'dead' ELSE saga_state END,
			        attempts=$3, last_error=$4
			  WHERE id=$1`, e.ID, status, nextAttempts, msg)
		return err
	}
	_, err := tx.Exec(ctx,
		`UPDATE public.outbox_events SET status=$2, attempts=$3, last_error=$4 WHERE id=$1`,
		e.ID, status, nextAttempts, msg)
	return err
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
