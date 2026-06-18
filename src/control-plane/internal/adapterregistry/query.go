package adapterregistry

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// mapMountLookupErr maps a row-scan error to ErrNotFound when the id cannot name
// a row: no rows, OR a malformed id that fails the uuid cast (SQLSTATE 22P02 —
// e.g. "", "123", "unknown-mount-zzz"). A malformed mount id is not-found by
// construction, never a 500. Any other error passes through unchanged.
func mapMountLookupErr(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "22P02" {
		return ErrNotFound
	}
	return err
}

// List returns tenant database metadata, newest first. Defense-in-depth: the
// query binds tenant_id EXPLICITLY (atop RLS), so isolation never depends on
// the DB role / RLS being active — a self-serve /me/mounts caller must only
// ever see its OWN mounts even if the connection bypasses RLS.
func (s *Service) List(ctx context.Context, userID string) ([]TenantDatabase, error) {
	out := make([]TenantDatabase, 0)
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx,
			`SELECT id::text, tenant_id::text, engine, name, created_at::text, last_healthy_at::text
			   FROM public.tenant_databases
			  WHERE tenant_id = $1
			  ORDER BY created_at DESC`, userID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var d TenantDatabase
			if err := rows.Scan(&d.ID, &d.TenantID, &d.Engine, &d.Name, &d.CreatedAt, &d.LastHealthyAt); err != nil {
				return err
			}
			out = append(out, d)
		}
		return rows.Err()
	})
	return out, err
}

// FindOne returns a single tenant database metadata row.
func (s *Service) FindOne(ctx context.Context, userID, id string) (TenantDatabase, error) {
	var d TenantDatabase
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx,
			`SELECT id::text, tenant_id::text, engine, name, created_at::text, last_healthy_at::text
			   FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2`, id, userID)
		err := row.Scan(&d.ID, &d.TenantID, &d.Engine, &d.Name, &d.CreatedAt, &d.LastHealthyAt)
		return mapMountLookupErr(err)
	})
	return d, err
}
