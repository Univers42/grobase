/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   postgres_admin.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:46 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pg

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// AdminExec runs a privileged statement bypassing tenant scoping.
func (p *Postgres) AdminExec(ctx context.Context, sql string, args ...any) error {
	_, err := p.pool.Exec(ctx, sql, args...)
	return err
}

// AdminQuery runs a privileged query and returns rows.
func (p *Postgres) AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	return p.pool.Query(ctx, sql, args...)
}

// AdminQueryRow runs a privileged single-row query; the returned Row yields
// pgx.ErrNoRows from Scan when nothing matched, and surfaces a unique-violation
// (from an INSERT ... RETURNING) through Scan's error — bypassing tenant scoping.
func (p *Postgres) AdminQueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	return p.pool.QueryRow(ctx, sql, args...)
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
