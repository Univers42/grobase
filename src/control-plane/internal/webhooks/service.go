package webhooks

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ErrNotFound is returned when a webhook row does not exist (or is not visible
// under the current tenant scope).
var ErrNotFound = errors.New("webhook not found")

// ErrConflict is returned on the (tenant_id, name) unique violation.
var ErrConflict = errors.New("webhook with that name already exists")

// Service owns CRUD on webhook_subscriptions and the delivery ledger.
type Service struct {
	db  *shared.Postgres
	log *slog.Logger
}

// NewService wires the DB pool.
func NewService(db *shared.Postgres, log *slog.Logger) *Service {
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

// Create inserts a subscription under the caller's tenant scope.
func (s *Service) Create(ctx context.Context, tenantID string, req CreateRequest) (Subscription, error) {
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

	var sub Subscription
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, `
			INSERT INTO public.webhook_subscriptions
			       (tenant_id, name, url, secret, event_types, aggregates,
			        active, headers, max_attempts, timeout_ms)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10)
			RETURNING id::text, tenant_id, name, url, event_types, aggregates,
			          active, headers::text, max_attempts, timeout_ms,
			          created_at::text, updated_at::text`,
			tenantID, req.Name, req.URL, req.Secret,
			coalesceStrSlice(req.EventTypes, "*"),
			coalesceStrSlice(req.Aggregates, "*"),
			active, string(headers), maxAttempts, timeoutMs,
		)
		return scanSubscription(row, &sub)
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return Subscription{}, ErrConflict
		}
		return Subscription{}, err
	}
	return sub, nil
}

// List returns all subscriptions for the caller's tenant.
func (s *Service) List(ctx context.Context, tenantID string) ([]Subscription, error) {
	out := make([]Subscription, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, tenant_id, name, url, event_types, aggregates,
			       active, headers::text, max_attempts, timeout_ms,
			       created_at::text, updated_at::text
			  FROM public.webhook_subscriptions
			 ORDER BY created_at DESC`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var sub Subscription
			if err := scanSubscription(rows, &sub); err != nil {
				return err
			}
			out = append(out, sub)
		}
		return rows.Err()
	})
	return out, err
}

// FindOne returns a single subscription by ID.
func (s *Service) FindOne(ctx context.Context, tenantID, id string) (Subscription, error) {
	var sub Subscription
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, `
			SELECT id::text, tenant_id, name, url, event_types, aggregates,
			       active, headers::text, max_attempts, timeout_ms,
			       created_at::text, updated_at::text
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
		row := tx.QueryRow(ctx, `
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
			nullableStrSlice(req.EventTypes), nullableStrSlice(req.Aggregates),
			req.Active, nullableHeaders(req.Headers),
			req.MaxAttempts, req.TimeoutMs,
		)
		err := scanSubscription(row, &sub)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return sub, err
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

// Deliveries returns the most recent delivery attempts for a subscription.
func (s *Service) Deliveries(ctx context.Context, tenantID, subscriptionID string, limit int) ([]Delivery, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	out := make([]Delivery, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, subscription_id::text, tenant_id, event_id, aggregate, event_type,
			       status, attempts, last_error, last_status_code,
			       next_attempt_at::text, delivered_at::text, created_at::text
			  FROM public.webhook_deliveries
			 WHERE subscription_id = $1
			 ORDER BY created_at DESC
			 LIMIT $2`, subscriptionID, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var d Delivery
			if err := rows.Scan(&d.ID, &d.SubscriptionID, &d.TenantID, &d.EventID,
				&d.Aggregate, &d.EventType, &d.Status, &d.Attempts,
				&d.LastError, &d.LastStatusCode, &d.NextAttemptAt,
				&d.DeliveredAt, &d.CreatedAt); err != nil {
				return err
			}
			out = append(out, d)
		}
		return rows.Err()
	})
	return out, err
}

// scannable is the small surface common to pgx.Row and pgx.Rows.
type scannable interface {
	Scan(dest ...any) error
}

func scanSubscription(row scannable, sub *Subscription) error {
	var headersJSON string
	if err := row.Scan(&sub.ID, &sub.TenantID, &sub.Name, &sub.URL,
		&sub.EventTypes, &sub.Aggregates, &sub.Active, &headersJSON,
		&sub.MaxAttempts, &sub.TimeoutMs,
		&sub.CreatedAt, &sub.UpdatedAt); err != nil {
		return err
	}
	sub.Headers = map[string]string{}
	if headersJSON != "" {
		_ = json.Unmarshal([]byte(headersJSON), &sub.Headers)
	}
	return nil
}

func coalesceMap(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

func coalesceStrSlice(s []string, fallback string) []string {
	if len(s) == 0 {
		return []string{fallback}
	}
	return s
}

func nullableStrSlice(s []string) any {
	if s == nil {
		return nil
	}
	return s
}

func nullableHeaders(m map[string]string) any {
	if m == nil {
		return nil
	}
	b, _ := json.Marshal(m)
	return string(b)
}
