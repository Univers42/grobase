package scheduler

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

// ErrNotFound is returned when a schedule row does not exist (or is not visible
// under the current tenant scope).
var ErrNotFound = errors.New("function schedule not found")

// ErrConflict is returned on the (tenant_id, name) unique violation.
var ErrConflict = errors.New("function schedule with that name already exists")

var nameRe = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_-]{0,63}$`)

// ScheduleRow is the public function-schedule metadata view.
type ScheduleRow struct {
	ID           string `json:"id"`
	TenantID     string `json:"tenant_id"`
	Name         string `json:"name"`
	FunctionName string `json:"function_name"`
	ScheduleExpr string `json:"schedule_expr"`
	Payload      string `json:"payload"`
	Enabled      bool   `json:"enabled"`
	TimeoutMs    int    `json:"timeout_ms"`
	LastRun      string `json:"last_run"`
	NextRun      string `json:"next_run"`
	LastStatus   string `json:"last_status"`
	CreatedAt    string `json:"created_at"`
	UpdatedAt    string `json:"updated_at"`
}

// CreateRequest is the JSON body for POST /v1/function-schedules.
type CreateRequest struct {
	Name         string          `json:"name"`
	FunctionName string          `json:"function_name"`
	ScheduleExpr string          `json:"schedule_expr"`
	Payload      json.RawMessage `json:"payload"`
	Enabled      *bool           `json:"enabled"`
	TimeoutMs    int             `json:"timeout_ms"`
}

// Validate enforces the same constraints as the DB CHECK constraints plus a
// real parse of the schedule expression.
func (r CreateRequest) Validate() error {
	if l := len(r.Name); l < 1 || l > 64 {
		return fmt.Errorf("name must be 1..64 chars")
	}
	if !nameRe.MatchString(r.FunctionName) {
		return fmt.Errorf("function_name must match [a-zA-Z][a-zA-Z0-9_-]{0,63}")
	}
	if _, err := ParseSchedule(r.ScheduleExpr); err != nil {
		return fmt.Errorf("schedule_expr: %w", err)
	}
	if r.TimeoutMs < 0 || r.TimeoutMs > 60_000 {
		return fmt.Errorf("timeout_ms must be 0..60000")
	}
	return nil
}

// defaults resolves the create-time defaults (enabled, timeout, payload).
func (r CreateRequest) defaults() (bool, int, string) {
	enabled := true
	if r.Enabled != nil {
		enabled = *r.Enabled
	}
	timeoutMs := r.TimeoutMs
	if timeoutMs == 0 {
		timeoutMs = 5000
	}
	payload := "{}"
	if len(r.Payload) > 0 {
		payload = string(r.Payload)
	}
	return enabled, timeoutMs, payload
}

// UpdateRequest is the JSON body for PATCH /v1/function-schedules/:id.
type UpdateRequest struct {
	FunctionName *string         `json:"function_name"`
	ScheduleExpr *string         `json:"schedule_expr"`
	Payload      json.RawMessage `json:"payload"`
	Enabled      *bool           `json:"enabled"`
	TimeoutMs    *int            `json:"timeout_ms"`
}

// normalize validates the schedule expression (if present) and resolves the
// payload argument passed to the UPDATE (nil leaves the column untouched).
func (r UpdateRequest) normalize() (any, error) {
	if r.ScheduleExpr != nil {
		if _, err := ParseSchedule(*r.ScheduleExpr); err != nil {
			return nil, fmt.Errorf("schedule_expr: %w", err)
		}
	}
	var payload any
	if len(r.Payload) > 0 {
		payload = string(r.Payload)
	}
	return payload, nil
}
