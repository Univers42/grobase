package scheduler

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// Service owns CRUD on function_schedules.
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool.
func NewService(db *pg.Postgres, log *slog.Logger) *Service {
	return &Service{db: db, log: log}
}

// EnsureSchema verifies the table exists (the real DDL lives in migration 036).
func (s *Service) EnsureSchema(ctx context.Context) error {
	const q = `SELECT 1 FROM information_schema.tables
	            WHERE table_schema = 'public' AND table_name = 'function_schedules'`
	rows, err := s.db.AdminQuery(ctx, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return errors.New("public.function_schedules missing — run migration 036_function_schedules.sql")
	}
	return nil
}

// List returns all schedules for the caller's tenant.
func (s *Service) List(ctx context.Context, tenantID string) ([]ScheduleRow, error) {
	out := make([]ScheduleRow, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, scheduleSelect+` ORDER BY created_at DESC`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var row ScheduleRow
			if err := scanSchedule(rows, &row); err != nil {
				return err
			}
			out = append(out, row)
		}
		return rows.Err()
	})
	return out, err
}

const scheduleSelect = `
	SELECT id::text, tenant_id, name, function_name, schedule_expr, payload::text,
	       enabled, timeout_ms,
	       COALESCE(last_run::text,''), next_run::text,
	       COALESCE(last_status,''), created_at::text, updated_at::text
	  FROM public.function_schedules`

func scanSchedule(row scannable, s *ScheduleRow) error {
	return row.Scan(&s.ID, &s.TenantID, &s.Name, &s.FunctionName, &s.ScheduleExpr,
		&s.Payload, &s.Enabled, &s.TimeoutMs, &s.LastRun, &s.NextRun,
		&s.LastStatus, &s.CreatedAt, &s.UpdatedAt)
}

type scannable interface {
	Scan(dest ...any) error
}
