/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   types.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:55:02 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:55:03 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package scheduler

import (
	"encoding/json"
	"fmt"
	"regexp"
)

// schedulerErr is a const-able error type, so the package's sentinels live in
// the const block (no package-level var). Error() returns the message verbatim,
// so errors.Is/%w and the message bytes are identical to errors.New.
type schedulerErr string

func (e schedulerErr) Error() string { return string(e) }

// ErrNotFound is returned when a schedule row does not exist (or is not visible
// under the current tenant scope).
const ErrNotFound schedulerErr = "function schedule not found"

// ErrConflict is returned on the (tenant_id, name) unique violation.
const ErrConflict schedulerErr = "function schedule with that name already exists"

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
	// perf: regex compiled per call — validation path (API-rate, not hot).
	nameRe := regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_-]{0,63}$`)
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
