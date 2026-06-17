package shared

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// TenantTx runs fn inside a transaction scoped to userID via RLS GUCs. It
// replicates the legacy NestJS PostgresService contract: set
// app.current_user_id + request.jwt.claims so existing RLS policies
// (auth.current_user_id()) stay enforced. The tx is rolled back on any error.
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
