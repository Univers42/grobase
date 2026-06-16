package shared

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Postgres wraps a pgx pool and provides admin + tenant-scoped query helpers.
//
// Tenant queries replicate the legacy NestJS PostgresService contract: they run
// inside a transaction that sets `app.current_user_id` and `request.jwt.claims`
// so existing RLS policies (auth.current_user_id()) stay enforced.
type Postgres struct {
	pool *pgxpool.Pool
}

// NewPostgres opens a pooled connection from a libpq URL.
func NewPostgres(ctx context.Context, url string) (*Postgres, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

// Close releases the pool.
func (p *Postgres) Close() { p.pool.Close() }

// Ping checks connectivity (used by readiness probe).
func (p *Postgres) Ping(ctx context.Context) error { return p.pool.Ping(ctx) }

// AdminExec runs a privileged statement bypassing tenant scoping.
func (p *Postgres) AdminExec(ctx context.Context, sql string, args ...any) error {
	_, err := p.pool.Exec(ctx, sql, args...)
	return err
}

// AdminQuery runs a privileged query and returns rows.
func (p *Postgres) AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	return p.pool.Query(ctx, sql, args...)
}

// Begin starts a transaction on a pooled connection. The returned pgx.Tx owns
// its connection until Commit/Rollback — used where a read-then-write must be
// atomic under a lock (e.g. the audit chain's read-tip / append-link, which
// takes a per-tenant pg_advisory_xact_lock inside the tx). Privileged
// (BYPASSRLS) like AdminExec/AdminQuery: it does NOT set tenant GUCs (that is
// TenantTx's job); a caller needing RLS scoping uses TenantTx instead.
func (p *Postgres) Begin(ctx context.Context) (pgx.Tx, error) {
	return p.pool.Begin(ctx)
}

// AcquireConn checks out ONE dedicated connection from the pool. The caller owns
// it until Release(). This is the only way to get connection affinity, which a
// session-scoped Postgres advisory lock (pg_advisory_lock / pg_advisory_unlock)
// REQUIRES: the lock lives on the backend connection that took it, so acquiring
// and releasing it on the SAME *pgxpool.Conn is the difference between a real
// mutual exclusion and a no-op across pooled connections.
func (p *Postgres) AcquireConn(ctx context.Context) (*pgxpool.Conn, error) {
	return p.pool.Acquire(ctx)
}

// TenantTx runs fn inside a transaction scoped to userID via RLS GUCs.
func (p *Postgres) TenantTx(ctx context.Context, userID string, fn func(pgx.Tx) error) error {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	claims, _ := json.Marshal(map[string]string{"sub": userID})
	if _, err := tx.Exec(ctx,
		`SELECT set_config('app.current_user_id', $1, true), set_config('request.jwt.claims', $2, true)`,
		userID, string(claims),
	); err != nil {
		return fmt.Errorf("set tenant context: %w", err)
	}

	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
