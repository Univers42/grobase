package tenants

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func scanTenant(row interface{ Scan(...any) error }, t *Tenant) error {
	var metaJSON string
	if err := row.Scan(&t.UUID, &t.ID, &t.Name, &t.Status, &t.Plan, &t.OwnerUserID,
		&metaJSON, &t.CreatedAt, &t.UpdatedAt); err != nil {
		return err
	}
	t.Metadata = map[string]any{}
	if metaJSON != "" {
		_ = json.Unmarshal([]byte(metaJSON), &t.Metadata)
	}
	return nil
}

// queryOne wraps pool.QueryRow so we can keep all SQL on the admin path.
func (s *Service) queryOne(ctx context.Context, sql string, args ...any) (pgx.Row, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return &singleRow{rows: rows}, nil
}

// exec runs a non-returning statement via the admin pool, returning the tag.
func (s *Service) exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return pgconn.CommandTag{}, err
	}
	for rows.Next() { /* drain */
	}
	return rows.CommandTag(), rows.Err()
}

// singleRow lets a multi-row pgx.Rows behave like a single pgx.Row, returning
// pgx.ErrNoRows when the cursor is empty.
type singleRow struct {
	rows pgx.Rows
}

func (s *singleRow) Scan(dest ...any) error {
	defer s.rows.Close()
	if !s.rows.Next() {
		if err := s.rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return s.rows.Scan(dest...)
}
