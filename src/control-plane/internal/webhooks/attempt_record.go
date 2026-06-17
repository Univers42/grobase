package webhooks

import (
	"context"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// deliveryOutcomeHelp documents the baas_webhook_deliveries_total counter:
// every delivery attempt resolves to exactly one outcome label.
const deliveryOutcomeHelp = "Webhook delivery attempts by terminal outcome (success|retry|dead)"

func (d *Dispatcher) recordAttempt(ctx context.Context,
	subscriptionID, eventID string, attempts, maxAttempts, statusCode int, attemptErr error) {
	if attemptErr == nil {
		d.recordSuccess(ctx, subscriptionID, eventID, attempts, statusCode)
		return
	}
	errMsg := attemptErr.Error()
	if attempts >= maxAttempts {
		d.recordDead(ctx, subscriptionID, eventID, attempts, statusCode, errMsg)
		return
	}
	d.recordRetry(ctx, subscriptionID, eventID, attempts, statusCode, errMsg)
}

func (d *Dispatcher) recordSuccess(ctx context.Context, subscriptionID, eventID string, attempts, statusCode int) {
	_ = d.db.AdminExec(ctx, `
		UPDATE public.webhook_deliveries
		   SET status = 'success', attempts = $3, last_status_code = $4,
		       last_error = NULL, delivered_at = now()
		 WHERE subscription_id = $1::uuid AND event_id = $2`,
		subscriptionID, eventID, attempts, statusCode)
	observability.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "success")
}

func (d *Dispatcher) recordDead(ctx context.Context,
	subscriptionID, eventID string, attempts, statusCode int, errMsg string) {
	_ = d.db.AdminExec(ctx, `
		UPDATE public.webhook_deliveries
		   SET status = 'dead', attempts = $3, last_status_code = $4,
		       last_error = $5
		 WHERE subscription_id = $1::uuid AND event_id = $2`,
		subscriptionID, eventID, attempts, pg.NullableInt(statusCode), errMsg)
	observability.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "dead")
	d.log.Warn("delivery moved to DLQ", "sub", subscriptionID, "event", eventID, "attempts", attempts)
}

func (d *Dispatcher) recordRetry(ctx context.Context,
	subscriptionID, eventID string, attempts, statusCode int, errMsg string) {
	observability.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "retry")
	next := time.Now().Add(backoff(attempts))
	_ = d.db.AdminExec(ctx, `
		UPDATE public.webhook_deliveries
		   SET status = 'pending', attempts = $3, last_status_code = $4,
		       last_error = $5, next_attempt_at = $6
		 WHERE subscription_id = $1::uuid AND event_id = $2`,
		subscriptionID, eventID, attempts, pg.NullableInt(statusCode), errMsg, next)
}
