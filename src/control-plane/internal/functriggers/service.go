package functriggers

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ErrNotFound is returned when a trigger row does not exist (or is not visible
// under the current tenant scope).
var ErrNotFound = errors.New("function trigger not found")

// ErrConflict is returned on the (tenant_id, name) unique violation.
var ErrConflict = errors.New("function trigger with that name already exists")

// Service owns CRUD on function_triggers and the delivery ledger.
type Service struct {
	db  *shared.Postgres
	log *slog.Logger
}

// NewService wires the DB pool.
func NewService(db *shared.Postgres, log *slog.Logger) *Service {
	return &Service{db: db, log: log}
}

// EnsureSchema is a defensive idempotent check; the real DDL lives in migration
// 035. It just verifies the table exists so the service fails fast.
func (s *Service) EnsureSchema(ctx context.Context) error {
	const q = `SELECT 1 FROM information_schema.tables
	            WHERE table_schema = 'public' AND table_name = 'function_triggers'`
	rows, err := s.db.AdminQuery(ctx, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return errors.New("public.function_triggers missing — run migration 035_function_triggers.sql")
	}
	return nil
}

// Create inserts a trigger under the caller's tenant scope.
func (s *Service) Create(ctx context.Context, tenantID string, req CreateRequest) (Trigger, error) {
	enabled := true
	if req.Enabled != nil {
		enabled = *req.Enabled
	}
	maxAttempts := req.MaxAttempts
	if maxAttempts == 0 {
		maxAttempts = 8
	}
	timeoutMs := req.TimeoutMs
	if timeoutMs == 0 {
		timeoutMs = 5000
	}

	var tr Trigger
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, `
			INSERT INTO public.function_triggers
			       (tenant_id, name, function_name, event_types, aggregates,
			        enabled, max_attempts, timeout_ms)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
			RETURNING id::text, tenant_id, name, function_name, event_types, aggregates,
			          enabled, max_attempts, timeout_ms, created_at::text, updated_at::text`,
			tenantID, req.Name, req.FunctionName,
			coalesceStrSlice(req.EventTypes, "*"),
			coalesceStrSlice(req.Aggregates, "*"),
			enabled, maxAttempts, timeoutMs,
		)
		return scanTrigger(row, &tr)
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return Trigger{}, ErrConflict
		}
		return Trigger{}, err
	}
	return tr, nil
}

// List returns all triggers for the caller's tenant.
func (s *Service) List(ctx context.Context, tenantID string) ([]Trigger, error) {
	out := make([]Trigger, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, tenant_id, name, function_name, event_types, aggregates,
			       enabled, max_attempts, timeout_ms, created_at::text, updated_at::text
			  FROM public.function_triggers
			 ORDER BY created_at DESC`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var tr Trigger
			if err := scanTrigger(rows, &tr); err != nil {
				return err
			}
			out = append(out, tr)
		}
		return rows.Err()
	})
	return out, err
}

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
		row := tx.QueryRow(ctx, `
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
			nullableStrSlice(req.EventTypes), nullableStrSlice(req.Aggregates),
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
		for rows.Next() {
			var d Delivery
			if err := rows.Scan(&d.ID, &d.TriggerID, &d.TenantID, &d.FunctionName,
				&d.EventID, &d.Aggregate, &d.EventType, &d.Status, &d.Attempts,
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

func scanTrigger(row scannable, tr *Trigger) error {
	return row.Scan(&tr.ID, &tr.TenantID, &tr.Name, &tr.FunctionName,
		&tr.EventTypes, &tr.Aggregates, &tr.Enabled,
		&tr.MaxAttempts, &tr.TimeoutMs, &tr.CreatedAt, &tr.UpdatedAt)
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
