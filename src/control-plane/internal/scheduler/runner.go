package scheduler

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// Runner polls function_schedules for due rows and invokes the target function
// on the functions-runtime, then advances next_run by the schedule's interval.
// It uses the admin pool (RLS-bypass) because the loop has no tenant context.
type Runner struct {
	db         *shared.Postgres
	log        *slog.Logger
	httpClient *http.Client
	runtimeURL string
	tick       time.Duration
	now        func() time.Time // injectable for tests
}

// RunnerConfig wires the scheduler runner.
type RunnerConfig struct {
	RuntimeURL string
	Tick       time.Duration
}

// NewRunner builds a runner; the caller owns the lifecycle.
func NewRunner(db *shared.Postgres, log *slog.Logger, cfg RunnerConfig) *Runner {
	if cfg.RuntimeURL == "" {
		cfg.RuntimeURL = "http://functions-runtime:3060"
	}
	if cfg.Tick == 0 {
		cfg.Tick = 10 * time.Second
	}
	return &Runner{
		db:         db,
		log:        log,
		httpClient: &http.Client{Timeout: 30 * time.Second},
		runtimeURL: strings.TrimRight(cfg.RuntimeURL, "/"),
		tick:       cfg.Tick,
		now:        time.Now,
	}
}

// Run blocks until ctx is cancelled, scanning for due schedules each tick.
func (r *Runner) Run(ctx context.Context) error {
	t := time.NewTicker(r.tick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			r.scanAndFire(ctx)
		}
	}
}

func (r *Runner) scanAndFire(ctx context.Context) {
	now := r.now()
	rows, err := r.db.AdminQuery(ctx, `
		SELECT id::text, tenant_id, function_name, schedule_expr, payload::text,
		       timeout_ms, last_run, next_run
		  FROM public.function_schedules
		 WHERE enabled = true AND next_run <= now()
		 ORDER BY next_run
		 LIMIT 100`)
	if err != nil {
		r.log.Warn("schedule scan failed", "err", err)
		return
	}
	due := collectDue(rows)
	rows.Close()

	for _, d := range due {
		r.fire(ctx, d, now)
	}
}

// collectDue scans the due-schedule rows; unscannable rows are skipped.
func collectDue(rows pgx.Rows) []dueRow {
	due := make([]dueRow, 0)
	for rows.Next() {
		var d dueRow
		var lastRun *time.Time
		if err := rows.Scan(&d.id, &d.tenantID, &d.functionName, &d.scheduleExpr,
			&d.payload, &d.timeoutMs, &lastRun, &d.nextRun); err != nil {
			continue
		}
		if lastRun != nil {
			d.lastRun = *lastRun
			d.hasLastRun = true
		}
		due = append(due, d)
	}
	return due
}

// fire invokes one schedule and advances its next_run. next_run is advanced
// FIRST (anchored on the previous next_run so cadence is preserved) so a slow
// invoke doesn't cause the same row to be picked up twice.
func (r *Runner) fire(ctx context.Context, d dueRow, now time.Time) {
	sched, err := ParseSchedule(d.scheduleExpr)
	if err != nil {
		r.log.Warn("bad schedule expr — disabling", "id", d.id, "expr", d.scheduleExpr, "err", err)
		_ = r.db.AdminExec(ctx, `UPDATE public.function_schedules SET enabled=false, last_error=$2 WHERE id=$1`, d.id, err.Error())
		return
	}
	// Anchor the cadence on the scheduled next_run, not on wall-clock now, so
	// drift doesn't accumulate; Next() catches up if we missed intervals.
	next := sched.Next(d.nextRun, now)

	status, invErr := r.invoke(ctx, d, sched.Interval)
	if invErr != nil {
		_ = r.db.AdminExec(ctx, `
			UPDATE public.function_schedules
			   SET last_run=$2, next_run=$3, last_status='error', last_error=$4
			 WHERE id=$1`, d.id, now, next, invErr.Error())
		r.log.Warn("scheduled invoke failed", "id", d.id, "fn", d.functionName, "status", status, "err", invErr)
		return
	}
	_ = r.db.AdminExec(ctx, `
		UPDATE public.function_schedules
		   SET last_run=$2, next_run=$3, last_status='success', last_error=NULL
		 WHERE id=$1`, d.id, now, next)
}
