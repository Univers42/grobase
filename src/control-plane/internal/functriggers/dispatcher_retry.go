package functriggers

import (
	"context"
	"time"
)

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

func (d *Dispatcher) scanAndRetry(ctx context.Context) {
	rows, err := d.db.AdminQuery(ctx, `
		SELECT trigger_id::text, event_id
		  FROM public.function_deliveries
		 WHERE status = 'pending' AND next_attempt_at <= now() AND attempts > 0
		 ORDER BY next_attempt_at
		 LIMIT 100`)
	if err != nil {
		d.log.Warn("retry scan failed", "err", err)
		return
	}
	type job struct{ triggerID, eventID string }
	jobs := make([]job, 0)
	for rows.Next() {
		var j job
		if err := rows.Scan(&j.triggerID, &j.eventID); err != nil {
			continue
		}
		jobs = append(jobs, j)
	}
	rows.Close()
	for _, j := range jobs {
		d.attempt(ctx, j.triggerID, j.eventID)
	}
}

// backoff returns the delay before the next attempt using exponential backoff
// capped at 5 minutes (mirrors webhooks).
func backoff(attempt int) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	d := time.Duration(1<<minInt(attempt, 9)) * time.Second
	cap := 5 * time.Minute
	if d > cap {
		d = cap
	}
	return d
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
