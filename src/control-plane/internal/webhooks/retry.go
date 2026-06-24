/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   retry.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:01:18 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:01:19 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package webhooks

import (
	"context"
	"time"
)

// retryLoop scans for pending deliveries that have passed their next_attempt_at
// (failed previous attempts) and re-attempts them.
func (d *Dispatcher) retryLoop(ctx context.Context) {
	t := time.NewTicker(d.retryPeriod)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		d.scanAndRetry(ctx)
	}
}

// retryJob is one pending delivery to re-attempt.
type retryJob struct{ subID, eventID string }

func (d *Dispatcher) scanAndRetry(ctx context.Context) {
	rows, err := d.db.AdminQuery(ctx, `
		SELECT subscription_id::text, event_id
		  FROM public.webhook_deliveries
		 WHERE status = 'pending' AND next_attempt_at <= now() AND attempts > 0
		 ORDER BY next_attempt_at
		 LIMIT 100`)
	if err != nil {
		d.log.Warn("retry scan failed", "err", err)
		return
	}
	jobs := collectRetryJobs(rows)
	rows.Close()
	for _, j := range jobs {
		d.attempt(ctx, j.subID, j.eventID)
	}
}

func collectRetryJobs(rows rowsScanner) []retryJob {
	jobs := make([]retryJob, 0)
	for rows.Next() {
		var j retryJob
		if err := rows.Scan(&j.subID, &j.eventID); err != nil {
			continue
		}
		jobs = append(jobs, j)
	}
	return jobs
}

func (d *Dispatcher) sleep(ctx context.Context, dur time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(dur):
	}
}
