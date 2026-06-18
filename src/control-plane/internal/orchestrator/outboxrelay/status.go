package outboxrelay

import (
	"context"
	"sync/atomic"

	"github.com/jackc/pgx/v5"
)

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
