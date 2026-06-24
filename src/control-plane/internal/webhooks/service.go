/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:01:32 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:01:33 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package webhooks

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// webhooksErr is the package's const-error type: a sentinel is a typed string
// constant, so errors.Is / %w wrapping still work (equal value+type == equal
// error) with no package-level var. Error() returns the message verbatim.
// ErrNotFound is returned when a webhook row does not exist (or is not visible
// under the current tenant scope).
const ErrNotFound webhooksErr = "webhook not found"

// ErrConflict is returned on the (tenant_id, name) unique violation.
const ErrConflict webhooksErr = "webhook with that name already exists"

// Service owns CRUD on webhook_subscriptions and the delivery ledger.
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool.
func NewService(db *pg.Postgres, log *slog.Logger) *Service {
	return &Service{db: db, log: log}
}

// EnsureSchema is a defensive idempotent check. The real DDL lives in
// migration 031; this function just verifies the table exists so the service
// fails fast on misconfigured environments.
func (s *Service) EnsureSchema(ctx context.Context) error {
	const q = `SELECT 1 FROM information_schema.tables
	            WHERE table_schema = 'public' AND table_name = 'webhook_subscriptions'`
	rows, err := s.db.AdminQuery(ctx, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return errors.New("public.webhook_subscriptions missing — run migration 031_webhooks.sql")
	}
	return nil
}

// createArgs is the resolved insert tuple with defaults applied. Bundled into a
// struct so insertSubscription stays under the 4-parameter limit.
type createArgs struct {
	tenantID    string
	req         CreateRequest
	headers     string
	active      bool
	maxAttempts int
	timeoutMs   int
}

// Create inserts a subscription under the caller's tenant scope.
func (s *Service) Create(ctx context.Context, tenantID string, req CreateRequest) (Subscription, error) {
	args := resolveCreateArgs(tenantID, req)
	var sub Subscription
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return insertSubscription(ctx, tx, args, &sub)
	})
	if err != nil {
		if pg.IsUniqueViolation(err) {
			return Subscription{}, ErrConflict
		}
		return Subscription{}, err
	}
	return sub, nil
}

// resolveCreateArgs applies the request defaults (active, max_attempts,
// timeout_ms) and marshals the headers into the insert tuple.
func resolveCreateArgs(tenantID string, req CreateRequest) createArgs {
	headers, _ := json.Marshal(coalesceMap(req.Headers))
	active := true
	if req.Active != nil {
		active = *req.Active
	}
	maxAttempts := req.MaxAttempts
	if maxAttempts == 0 {
		maxAttempts = 8
	}
	timeoutMs := req.TimeoutMs
	if timeoutMs == 0 {
		timeoutMs = 5000
	}
	return createArgs{
		tenantID: tenantID, req: req, headers: string(headers),
		active: active, maxAttempts: maxAttempts, timeoutMs: timeoutMs,
	}
}

func insertSubscription(ctx context.Context, tx pgx.Tx, a createArgs, sub *Subscription) error {
	row := tx.QueryRow(
		ctx, `
		INSERT INTO public.webhook_subscriptions
		       (tenant_id, name, url, secret, event_types, aggregates,
		        active, headers, max_attempts, timeout_ms)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10)
		RETURNING id::text, tenant_id, name, url, event_types, aggregates,
		          active, headers::text, max_attempts, timeout_ms,
		          created_at::text, updated_at::text`,
		a.tenantID, a.req.Name, a.req.URL, a.req.Secret,
		coalesceStrSlice(a.req.EventTypes, "*"),
		coalesceStrSlice(a.req.Aggregates, "*"),
		a.active, a.headers, a.maxAttempts, a.timeoutMs,
	)
	return scanSubscription(row, sub)
}
