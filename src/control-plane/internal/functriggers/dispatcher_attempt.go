/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dispatcher_attempt.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:44:14 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:44:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package functriggers

import (
	"context"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// attemptResult carries the outcome of one invoke through recordAttempt.
type attemptResult struct {
	triggerID, eventID                string
	attempts, maxAttempts, statusCode int
	attemptErr                        error
}

// outcome carries the fields written by recordDead and recordPending.
type outcome struct {
	triggerID, eventID   string
	attempts, statusCode int
	errMsg               string
}

func (d *Dispatcher) recordAttempt(ctx context.Context, r attemptResult) {
	if r.attemptErr == nil {
		d.recordSuccess(ctx, r.triggerID, r.eventID, r.attempts, r.statusCode)
		return
	}
	o := outcome{triggerID: r.triggerID, eventID: r.eventID, attempts: r.attempts, statusCode: r.statusCode, errMsg: r.attemptErr.Error()}
	if r.attempts >= r.maxAttempts {
		d.recordDead(ctx, o)
		return
	}
	d.recordPending(ctx, o)
}

func (d *Dispatcher) recordSuccess(ctx context.Context, triggerID, eventID string, attempts, statusCode int) {
	_ = d.db.AdminExec(ctx, `
		UPDATE public.function_deliveries
		   SET status = 'success', attempts = $3, last_status_code = $4,
		       last_error = NULL, delivered_at = now()
		 WHERE trigger_id = $1::uuid AND event_id = $2`,
		triggerID, eventID, attempts, statusCode)
}

func (d *Dispatcher) recordDead(ctx context.Context, o outcome) {
	_ = d.db.AdminExec(ctx, `
		UPDATE public.function_deliveries
		   SET status = 'dead', attempts = $3, last_status_code = $4,
		       last_error = $5
		 WHERE trigger_id = $1::uuid AND event_id = $2`,
		o.triggerID, o.eventID, o.attempts, pg.NullableInt(o.statusCode), o.errMsg)
	d.log.Warn("function delivery moved to DLQ", "trigger", o.triggerID, "event", o.eventID, "attempts", o.attempts)
}

func (d *Dispatcher) recordPending(ctx context.Context, o outcome) {
	next := time.Now().Add(backoff(o.attempts))
	_ = d.db.AdminExec(ctx, `
		UPDATE public.function_deliveries
		   SET status = 'pending', attempts = $3, last_status_code = $4,
		       last_error = $5, next_attempt_at = $6
		 WHERE trigger_id = $1::uuid AND event_id = $2`,
		o.triggerID, o.eventID, o.attempts, pg.NullableInt(o.statusCode), o.errMsg, next)
}
