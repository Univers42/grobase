package functriggers

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// FindOne returns a single trigger by ID.
func (s *Service) FindOne(ctx context.Context, tenantID, id string) (Trigger, error) {
	var tr Trigger
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, `
			SELECT id::text, tenant_id, name, function_name, event_types, aggregates,
			       enabled, max_attempts, timeout_ms, created_at::text, updated_at::text
			  FROM public.function_triggers
			 WHERE id = $1`, id)
		err := scanTrigger(row, &tr)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return tr, err
}

// Update mutates the fields present in the request.
func (s *Service) Update(ctx context.Context, tenantID, id string, req UpdateRequest) (Trigger, error) {
	var tr Trigger
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(
			ctx, `
			UPDATE public.function_triggers
			   SET function_name = COALESCE($2, function_name),
			       event_types   = COALESCE($3, event_types),
			       aggregates    = COALESCE($4, aggregates),
			       enabled       = COALESCE($5, enabled),
			       max_attempts  = COALESCE($6, max_attempts),
			       timeout_ms    = COALESCE($7, timeout_ms),
			       updated_at    = now()
			 WHERE id = $1
			 RETURNING id::text, tenant_id, name, function_name, event_types, aggregates,
			           enabled, max_attempts, timeout_ms, created_at::text, updated_at::text`,
			id, req.FunctionName,
			pg.NullableStrSlice(req.EventTypes), pg.NullableStrSlice(req.Aggregates),
			req.Enabled, req.MaxAttempts, req.TimeoutMs,
		)
		err := scanTrigger(row, &tr)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return tr, err
}

// Delete removes a trigger (and its delivery rows via cascade).
func (s *Service) Delete(ctx context.Context, tenantID, id string) error {
	return s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM public.function_triggers WHERE id = $1`, id)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// Deliveries returns the most recent delivery attempts for a trigger.
func (s *Service) Deliveries(ctx context.Context, tenantID, triggerID string, limit int) ([]Delivery, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	out := make([]Delivery, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, trigger_id::text, tenant_id, function_name, event_id, aggregate, event_type,
			       status, attempts, last_error, last_status_code,
			       next_attempt_at::text, delivered_at::text, created_at::text
			  FROM public.function_deliveries
			 WHERE trigger_id = $1
			 ORDER BY created_at DESC
			 LIMIT $2`, triggerID, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		return collectDeliveries(rows, &out)
	})
	return out, err
}
