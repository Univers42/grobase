package webhooks

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

const selectSubscriptionCols = `
	SELECT id::text, tenant_id, name, url, event_types, aggregates,
	       active, headers::text, max_attempts, timeout_ms,
	       created_at::text, updated_at::text`

// List returns all subscriptions for the caller's tenant.
func (s *Service) List(ctx context.Context, tenantID string) ([]Subscription, error) {
	out := make([]Subscription, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, selectSubscriptionCols+`
			  FROM public.webhook_subscriptions
			 ORDER BY created_at DESC`)
		if err != nil {
			return err
		}
		defer rows.Close()
		return collectSubscriptions(rows, &out)
	})
	return out, err
}

// FindOne returns a single subscription by ID.
func (s *Service) FindOne(ctx context.Context, tenantID, id string) (Subscription, error) {
	var sub Subscription
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, selectSubscriptionCols+`
			  FROM public.webhook_subscriptions
			 WHERE id = $1`, id)
		err := scanSubscription(row, &sub)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return sub, err
}

// Update mutates the fields present in the request.
func (s *Service) Update(ctx context.Context, tenantID, id string, req UpdateRequest) (Subscription, error) {
	var sub Subscription
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := updateSubscriptionRow(ctx, tx, id, req)
		err := scanSubscription(row, &sub)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return sub, err
}

func updateSubscriptionRow(ctx context.Context, tx pgx.Tx, id string, req UpdateRequest) pgx.Row {
	return tx.QueryRow(ctx, `
		UPDATE public.webhook_subscriptions
		   SET url          = COALESCE($2, url),
		       secret       = COALESCE($3, secret),
		       event_types  = COALESCE($4, event_types),
		       aggregates   = COALESCE($5, aggregates),
		       active       = COALESCE($6, active),
		       headers      = COALESCE($7::jsonb, headers),
		       max_attempts = COALESCE($8, max_attempts),
		       timeout_ms   = COALESCE($9, timeout_ms),
		       updated_at   = now()
		 WHERE id = $1
		 RETURNING id::text, tenant_id, name, url, event_types, aggregates,
		           active, headers::text, max_attempts, timeout_ms,
		           created_at::text, updated_at::text`,
		id,
		req.URL, req.Secret,
		pg.NullableStrSlice(req.EventTypes), pg.NullableStrSlice(req.Aggregates),
		req.Active, nullableHeaders(req.Headers),
		req.MaxAttempts, req.TimeoutMs,
	)
}

// Delete removes a subscription (and its delivery rows via cascade).
func (s *Service) Delete(ctx context.Context, tenantID, id string) error {
	return s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM public.webhook_subscriptions WHERE id = $1`, id)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}
