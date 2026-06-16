// Package functriggers implements the tenant-scoped DB-event -> function
// trigger registry (A2 Functions DX) plus the delivery path that invokes a
// deployed edge function when an outbox event matches an enabled trigger.
//
// It deliberately mirrors the internal/webhooks package: same matching rules,
// same delivery-ledger shape, same retry/DLQ semantics. The only difference is
// the delivery TARGET — instead of POSTing an external URL, the dispatcher
// POSTs the change payload to functions-runtime
// (POST <runtime>/v1/functions/<name>/invoke) with the trigger's tenant as the
// X-Baas-Tenant-Id header.
package functriggers

import (
	"fmt"
	"regexp"
)

// nameRe matches the runtime's function-name rule (server.ts badName()).
var nameRe = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_-]{0,63}$`)

// Trigger is a public function-trigger metadata view.
type Trigger struct {
	ID           string   `json:"id"`
	TenantID     string   `json:"tenant_id"`
	Name         string   `json:"name"`
	FunctionName string   `json:"function_name"`
	EventTypes   []string `json:"event_types"`
	Aggregates   []string `json:"aggregates"`
	Enabled      bool     `json:"enabled"`
	MaxAttempts  int      `json:"max_attempts"`
	TimeoutMs    int      `json:"timeout_ms"`
	CreatedAt    string   `json:"created_at"`
	UpdatedAt    string   `json:"updated_at"`
}

// CreateRequest is the JSON body for POST /v1/function-triggers.
type CreateRequest struct {
	Name         string   `json:"name"`
	FunctionName string   `json:"function_name"`
	EventTypes   []string `json:"event_types"`
	Aggregates   []string `json:"aggregates"`
	Enabled      *bool    `json:"enabled"`
	MaxAttempts  int      `json:"max_attempts"`
	TimeoutMs    int      `json:"timeout_ms"`
}

// Validate enforces the same constraints as the DB CHECK constraints.
func (r CreateRequest) Validate() error {
	if l := len(r.Name); l < 1 || l > 64 {
		return fmt.Errorf("name must be 1..64 chars")
	}
	if !nameRe.MatchString(r.FunctionName) {
		return fmt.Errorf("function_name must match [a-zA-Z][a-zA-Z0-9_-]{0,63}")
	}
	if r.MaxAttempts < 0 || r.MaxAttempts > 32 {
		return fmt.Errorf("max_attempts must be 0..32")
	}
	if r.TimeoutMs < 0 || r.TimeoutMs > 60_000 {
		return fmt.Errorf("timeout_ms must be 0..60000")
	}
	return nil
}

// UpdateRequest is the JSON body for PATCH /v1/function-triggers/:id.
type UpdateRequest struct {
	FunctionName *string  `json:"function_name"`
	EventTypes   []string `json:"event_types"`
	Aggregates   []string `json:"aggregates"`
	Enabled      *bool    `json:"enabled"`
	MaxAttempts  *int     `json:"max_attempts"`
	TimeoutMs    *int     `json:"timeout_ms"`
}

// Delivery is a function-invocation delivery attempt ledger row.
type Delivery struct {
	ID             int64   `json:"id"`
	TriggerID      string  `json:"trigger_id"`
	TenantID       string  `json:"tenant_id"`
	FunctionName   string  `json:"function_name"`
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

// matches returns whether the trigger fires for this event. Identical semantics
// to webhooks: '*' is a wildcard, an empty pattern list matches everything, and
// a disabled trigger never fires.
func (t Trigger) matches(aggregate, eventType string) bool {
	if !t.Enabled {
		return false
	}
	return matchAny(t.Aggregates, aggregate) && matchAny(t.EventTypes, eventType)
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
