package authz

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgconn"
)

// invalidParameter is SQLSTATE 22023, which the write primitive raises for an
// input it refuses (empty or over-long text).
const invalidParameter = "22023"

// ReplaceTuples validates req against app's stored model, then replaces the
// tuple set of (object, source) through authz.replace_source_tuples. It returns
// the number of rows changed; an unchanged set writes 0.
func (s *Store) ReplaceTuples(ctx context.Context, app string, req TuplesRequest) (int, error) {
	raw, err := s.GetModel(ctx, app)
	if err != nil {
		return 0, err
	}
	model, err := ParseModel(raw)
	if err != nil {
		return 0, err
	}
	p, err := model.PrepareTuples(req)
	if err != nil {
		return 0, err
	}
	var changed int
	err = s.db.AdminQueryRow(ctx, `SELECT authz.replace_source_tuples($1, $2, $3, $4, $5::jsonb)`,
		app, p.Object.Type, p.Object.ID, p.Source, string(p.JSON)).Scan(&changed)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == invalidParameter {
		return 0, badTuples("%s", pgErr.Message)
	}
	return changed, err
}
