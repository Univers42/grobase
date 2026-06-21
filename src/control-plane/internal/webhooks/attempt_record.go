/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   attempt_record.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:38 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:39 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package webhooks

import (
	"context"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// deliveryOutcomeHelp documents the baas_webhook_deliveries_total counter:
// every delivery attempt resolves to exactly one outcome label.
const deliveryOutcomeHelp = "Webhook delivery attempts by terminal outcome (success|retry|dead)"

// attemptOutcome identifies the delivery row being recorded and the attempt
// state shared by the success/retry/dead recorders.
type attemptOutcome struct {
	subscriptionID, eventID string
	attempts, statusCode    int
}

func (d *Dispatcher) recordAttempt(ctx context.Context,
	o attemptOutcome, maxAttempts int, attemptErr error,
) {
	if attemptErr == nil {
		d.recordSuccess(ctx, o.subscriptionID, o.eventID, o.attempts, o.statusCode)
		return
	}
	errMsg := attemptErr.Error()
	if o.attempts >= maxAttempts {
		d.recordDead(ctx, o, errMsg)
		return
	}
	d.recordRetry(ctx, o, errMsg)
}

func (d *Dispatcher) recordSuccess(ctx context.Context, subscriptionID, eventID string, attempts, statusCode int) {
	_ = d.db.AdminExec(ctx, `
		UPDATE public.webhook_deliveries
		   SET status = 'success', attempts = $3, last_status_code = $4,
		       last_error = NULL, delivered_at = now()
		 WHERE subscription_id = $1::uuid AND event_id = $2`,
		subscriptionID, eventID, attempts, statusCode)
	d.metrics.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "success")
}

func (d *Dispatcher) recordDead(ctx context.Context, o attemptOutcome, errMsg string) {
	_ = d.db.AdminExec(ctx, `
		UPDATE public.webhook_deliveries
		   SET status = 'dead', attempts = $3, last_status_code = $4,
		       last_error = $5
		 WHERE subscription_id = $1::uuid AND event_id = $2`,
		o.subscriptionID, o.eventID, o.attempts, pg.NullableInt(o.statusCode), errMsg)
	d.metrics.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "dead")
	d.log.Warn("delivery moved to DLQ", "sub", o.subscriptionID, "event", o.eventID, "attempts", o.attempts)
}

func (d *Dispatcher) recordRetry(ctx context.Context, o attemptOutcome, errMsg string) {
	d.metrics.IncCounter("baas_webhook_deliveries_total", deliveryOutcomeHelp, "outcome", "retry")
	next := time.Now().Add(backoff(o.attempts))
	_ = d.db.AdminExec(ctx, `
		UPDATE public.webhook_deliveries
		   SET status = 'pending', attempts = $3, last_status_code = $4,
		       last_error = $5, next_attempt_at = $6
		 WHERE subscription_id = $1::uuid AND event_id = $2`,
		o.subscriptionID, o.eventID, o.attempts, pg.NullableInt(o.statusCode), errMsg, next)
}
