// Package webhooks implements the tenant-scoped webhook subscription registry
// and the dispatcher worker that consumes outbox events from Redis Streams and
// POSTs HMAC-signed payloads to subscriber URLs with retry + DLQ semantics.
package webhooks

import (
	"fmt"
	"math/rand/v2"
	"net/url"
	"time"
)

// maxBackoff caps the exponential retry delay. The jittered result never
// exceeds it (jitter only fills the lower half — see backoff).
const maxBackoff = 5 * time.Minute

// Subscription is a public webhook subscription metadata view.
type Subscription struct {
	ID          string            `json:"id"`
	TenantID    string            `json:"tenant_id"`
	Name        string            `json:"name"`
	URL         string            `json:"url"`
	EventTypes  []string          `json:"event_types"`
	Aggregates  []string          `json:"aggregates"`
	Active      bool              `json:"active"`
	Headers     map[string]string `json:"headers"`
	MaxAttempts int               `json:"max_attempts"`
	TimeoutMs   int               `json:"timeout_ms"`
	CreatedAt   string            `json:"created_at"`
	UpdatedAt   string            `json:"updated_at"`
}

// CreateRequest is the JSON body for POST /v1/webhooks.
type CreateRequest struct {
	Name        string            `json:"name"`
	URL         string            `json:"url"`
	Secret      string            `json:"secret"`
	EventTypes  []string          `json:"event_types"`
	Aggregates  []string          `json:"aggregates"`
	Active      *bool             `json:"active"`
	Headers     map[string]string `json:"headers"`
	MaxAttempts int               `json:"max_attempts"`
	TimeoutMs   int               `json:"timeout_ms"`
}

// Validate enforces the same constraints as the DB CHECK constraints.
func (r CreateRequest) Validate() error {
	if l := len(r.Name); l < 1 || l > 64 {
		return fmt.Errorf("name must be 1..64 chars")
	}
	if r.URL == "" {
		return fmt.Errorf("url is required")
	}
	u, err := url.Parse(r.URL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return fmt.Errorf("url must be http(s)")
	}
	if r.Secret == "" {
		return fmt.Errorf("secret is required")
	}
	if r.MaxAttempts < 0 || r.MaxAttempts > 32 {
		return fmt.Errorf("max_attempts must be 0..32")
	}
	if r.TimeoutMs < 0 || r.TimeoutMs > 60_000 {
		return fmt.Errorf("timeout_ms must be 0..60000")
	}
	return nil
}

// UpdateRequest is the JSON body for PATCH /v1/webhooks/:id.
type UpdateRequest struct {
	URL         *string           `json:"url"`
	Secret      *string           `json:"secret"`
	EventTypes  []string          `json:"event_types"`
	Aggregates  []string          `json:"aggregates"`
	Active      *bool             `json:"active"`
	Headers     map[string]string `json:"headers"`
	MaxAttempts *int              `json:"max_attempts"`
	TimeoutMs   *int              `json:"timeout_ms"`
}

// Delivery is a webhook delivery attempt ledger row.
type Delivery struct {
	ID             int64   `json:"id"`
	SubscriptionID string  `json:"subscription_id"`
	TenantID       string  `json:"tenant_id"`
	EventID        string  `json:"event_id"`
	Aggregate      string  `json:"aggregate"`
	EventType      string  `json:"event_type"`
	Status         string  `json:"status"`
	Attempts       int     `json:"attempts"`
	LastError      *string `json:"last_error"`
	LastStatusCode *int    `json:"last_status_code"`
	NextAttemptAt  string  `json:"next_attempt_at"`
	DeliveredAt    *string `json:"delivered_at"`
	CreatedAt      string  `json:"created_at"`
}

// matches returns whether the subscription is interested in this event.
func (s Subscription) matches(aggregate, eventType string) bool {
	if !s.Active {
		return false
	}
	return matchAny(s.Aggregates, aggregate) && matchAny(s.EventTypes, eventType)
}

func matchAny(patterns []string, candidate string) bool {
	if len(patterns) == 0 {
		return true
	}
	for _, p := range patterns {
		if p == "*" || p == candidate {
			return true
		}
	}
	return false
}

// backoff returns the delay before the next attempt: exponential (2^attempt
// seconds) capped at 5 minutes, then EQUAL JITTER. Half the delay stays
// deterministic so the cap still bounds worst-case latency; the other half is
// randomized so a batch of deliveries that failed together (a subscriber
// outage) don't resynchronize their retries into a thundering herd the moment
// the endpoint recovers. Result is always within [d/2, d] — never over the cap.
//
// (Until now this was deterministic despite the doc-comment claiming jitter —
// the herd risk was real; see TestBackoffJitterBounds.)
func backoff(attempt int) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	d := time.Duration(1<<min(attempt, 9)) * time.Second
	if d > maxBackoff {
		d = maxBackoff
	}
	half := d / 2
	return half + time.Duration(rand.Int64N(int64(half)+1))
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
