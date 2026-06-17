package webhooks

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
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
	type job struct{ subID, eventID string }
	jobs := make([]job, 0)
	for rows.Next() {
		var j job
		if err := rows.Scan(&j.subID, &j.eventID); err != nil {
			continue
		}
		jobs = append(jobs, j)
	}
	rows.Close()
	for _, j := range jobs {
		d.attempt(ctx, j.subID, j.eventID)
	}
}

func sign(secret, body string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(body))
	return hex.EncodeToString(mac.Sum(nil))
}

func stringFromPayload(p map[string]any, key string) string {
	if p == nil {
		return ""
	}
	if v, ok := p[key].(string); ok {
		return v
	}
	return ""
}

func nullInt(n int) any {
	if n == 0 {
		return nil
	}
	return n
}

func (d *Dispatcher) sleep(ctx context.Context, dur time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(dur):
	}
}
