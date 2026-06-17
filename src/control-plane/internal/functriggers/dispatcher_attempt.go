package functriggers

import (
	"context"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func (d *Dispatcher) recordAttempt(ctx context.Context,
	triggerID, eventID string, attempts, maxAttempts, statusCode int, attemptErr error) {
	if attemptErr == nil {
		d.recordSuccess(ctx, triggerID, eventID, attempts, statusCode)
		return
	}
	errMsg := attemptErr.Error()
	if attempts >= maxAttempts {
		d.recordDead(ctx, triggerID, eventID, attempts, statusCode, errMsg)
		return
	}
	d.recordPending(ctx, triggerID, eventID, attempts, statusCode, errMsg)
}

func (d *Dispatcher) recordSuccess(ctx context.Context, triggerID, eventID string, attempts, statusCode int) {
	_ = d.db.AdminExec(ctx, `
		UPDATE public.function_deliveries
		   SET status = 'success', attempts = $3, last_status_code = $4,
		       last_error = NULL, delivered_at = now()
		 WHERE trigger_id = $1::uuid AND event_id = $2`,
		triggerID, eventID, attempts, statusCode)
}

func (d *Dispatcher) recordDead(ctx context.Context, triggerID, eventID string, attempts, statusCode int, errMsg string) {
	_ = d.db.AdminExec(ctx, `
		UPDATE public.function_deliveries
		   SET status = 'dead', attempts = $3, last_status_code = $4,
		       last_error = $5
		 WHERE trigger_id = $1::uuid AND event_id = $2`,
		triggerID, eventID, attempts, shared.NullableInt(statusCode), errMsg)
	d.log.Warn("function delivery moved to DLQ", "trigger", triggerID, "event", eventID, "attempts", attempts)
}

func (d *Dispatcher) recordPending(ctx context.Context, triggerID, eventID string, attempts, statusCode int, errMsg string) {
	next := time.Now().Add(backoff(attempts))
	_ = d.db.AdminExec(ctx, `
		UPDATE public.function_deliveries
		   SET status = 'pending', attempts = $3, last_status_code = $4,
		       last_error = $5, next_attempt_at = $6
		 WHERE trigger_id = $1::uuid AND event_id = $2`,
		triggerID, eventID, attempts, shared.NullableInt(statusCode), errMsg, next)
}
