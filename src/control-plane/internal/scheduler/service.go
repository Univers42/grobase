package scheduler

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"regexp"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
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

// UpdateRequest is the JSON body for PATCH /v1/function-schedules/:id.
type UpdateRequest struct {
	FunctionName *string         `json:"function_name"`
	ScheduleExpr *string         `json:"schedule_expr"`
	Payload      json.RawMessage `json:"payload"`
	Enabled      *bool           `json:"enabled"`
	TimeoutMs    *int            `json:"timeout_ms"`
}

// Service owns CRUD on function_schedules.
type Service struct {
	db  *shared.Postgres
	log *slog.Logger
}

// NewService wires the DB pool.
func NewService(db *shared.Postgres, log *slog.Logger) *Service {
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

// Create inserts a schedule under the caller's tenant scope. next_run is set to
// now() so a freshly-created schedule fires on the next scheduler tick.
func (s *Service) Create(ctx context.Context, tenantID string, req CreateRequest) (ScheduleRow, error) {
	enabled := true
	if req.Enabled != nil {
		enabled = *req.Enabled
	}
	timeoutMs := req.TimeoutMs
	if timeoutMs == 0 {
		timeoutMs = 5000
	}
	payload := "{}"
	if len(req.Payload) > 0 {
		payload = string(req.Payload)
	}

	var row ScheduleRow
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		r := tx.QueryRow(ctx, `
			INSERT INTO public.function_schedules
			       (tenant_id, name, function_name, schedule_expr, payload, enabled, timeout_ms, next_run)
			VALUES ($1,$2,$3,$4,$5::jsonb,$6,$7, now())
			RETURNING id::text, tenant_id, name, function_name, schedule_expr, payload::text,
			          enabled, timeout_ms,
			          COALESCE(last_run::text,''), next_run::text,
			          COALESCE(last_status,''), created_at::text, updated_at::text`,
			tenantID, req.Name, req.FunctionName, req.ScheduleExpr, payload, enabled, timeoutMs)
		return scanSchedule(r, &row)
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return ScheduleRow{}, ErrConflict
		}
		return ScheduleRow{}, err
	}
	return row, nil
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

// Delete removes a schedule.
func (s *Service) Delete(ctx context.Context, tenantID, id string) error {
	return s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM public.function_schedules WHERE id = $1`, id)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// Update mutates the fields present in the request.
func (s *Service) Update(ctx context.Context, tenantID, id string, req UpdateRequest) (ScheduleRow, error) {
	if req.ScheduleExpr != nil {
		if _, err := ParseSchedule(*req.ScheduleExpr); err != nil {
			return ScheduleRow{}, fmt.Errorf("schedule_expr: %w", err)
		}
	}
	var payload any
	if len(req.Payload) > 0 {
		payload = string(req.Payload)
	}
	var row ScheduleRow
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		r := tx.QueryRow(ctx, `
			UPDATE public.function_schedules
			   SET function_name = COALESCE($2, function_name),
			       schedule_expr = COALESCE($3, schedule_expr),
			       payload       = COALESCE($4::jsonb, payload),
			       enabled       = COALESCE($5, enabled),
			       timeout_ms    = COALESCE($6, timeout_ms),
			       updated_at    = now()
			 WHERE id = $1
			 RETURNING id::text, tenant_id, name, function_name, schedule_expr, payload::text,
			           enabled, timeout_ms,
			           COALESCE(last_run::text,''), next_run::text,
			           COALESCE(last_status,''), created_at::text, updated_at::text`,
			id, req.FunctionName, req.ScheduleExpr, payload, req.Enabled, req.TimeoutMs)
		err := scanSchedule(r, &row)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return row, err
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
