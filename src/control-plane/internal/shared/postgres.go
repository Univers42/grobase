package shared

import (
	"context"
	"fmt"

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
