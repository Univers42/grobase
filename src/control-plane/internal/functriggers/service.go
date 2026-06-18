package functriggers

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// functriggersErr is a const-able error type, so the package's sentinels live in
// the const block (no package-level var). Error() returns the message verbatim,
// so errors.Is/%w and the message bytes are identical to errors.New.
// ErrNotFound is returned when a trigger row does not exist (or is not visible
// under the current tenant scope).
const ErrNotFound functriggersErr = "function trigger not found"

// ErrConflict is returned on the (tenant_id, name) unique violation.
const ErrConflict functriggersErr = "function trigger with that name already exists"

// Service owns CRUD on function_triggers and the delivery ledger.
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool.
func NewService(db *pg.Postgres, log *slog.Logger) *Service {
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
	enabled, maxAttempts, timeoutMs := createDefaults(req)
	var tr Trigger
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(
			ctx, `
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
		if pg.IsUniqueViolation(err) {
			return Trigger{}, ErrConflict
		}
		return Trigger{}, err
	}
	return tr, nil
}

// createDefaults applies the same field defaults the DB CHECK/DEFAULT clauses
// would: enabled=true, max_attempts=8, timeout_ms=5000.
func createDefaults(req CreateRequest) (enabled bool, maxAttempts, timeoutMs int) {
	enabled = true
	if req.Enabled != nil {
		enabled = *req.Enabled
	}
	maxAttempts = req.MaxAttempts
	if maxAttempts == 0 {
		maxAttempts = 8
	}
	timeoutMs = req.TimeoutMs
	if timeoutMs == 0 {
		timeoutMs = 5000
	}
	return enabled, maxAttempts, timeoutMs
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
