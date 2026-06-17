package outboxrelay

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"

	redis "github.com/redis/go-redis/v9"
)

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
