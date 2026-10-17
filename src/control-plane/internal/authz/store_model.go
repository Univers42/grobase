package authz

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// DroppedError lists relations that still hold tuples but are absent from a
// proposed model (HTTP 409).
type DroppedError struct{ Relations []string }

func (e *DroppedError) Error() string {
	return fmt.Sprintf("model drops relations that still have tuples: %v", e.Relations)
}

// rowQuerier is the one-row read both a pool and a transaction offer.
type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func readModelJSON(ctx context.Context, q rowQuerier, app string) ([]byte, error) {
	var raw []byte
	err := q.QueryRow(ctx, `SELECT model FROM authz.models WHERE app = $1`, app).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNoModel
	}
	return raw, err
}

func readModel(ctx context.Context, q rowQuerier, app string) (*Model, error) {
	raw, err := readModelJSON(ctx, q, app)
	if err != nil {
		return nil, err
	}
	return ParseModel(raw)
}

// GetModel returns the stored model document of app, as jsonb normalized it.
func (s *Store) GetModel(ctx context.Context, app string) ([]byte, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	return readModelJSON(ctx, tx, app)
}

// PutModel validates raw and stores it as app's model. It refuses (DroppedError)
// a model that no longer declares a (type, relation) that still has tuples.
// Caveat: the check and the upsert share a transaction but not a lock on
// authz.tuples (the write primitive never reads models), so a tuple written
// in the gap survives with a relation the model no longer names. The
// evaluator never loads an unmodeled relation, so such a row is inert.
func (s *Store) PutModel(ctx context.Context, app string, raw []byte) error {
	model, err := ParseModel(raw)
	if err != nil {
		return err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	dropped, err := droppedRelations(ctx, tx, app, model)
	if err != nil {
		return err
	}
	if len(dropped) > 0 {
		return &DroppedError{Relations: dropped}
	}
	_, err = tx.Exec(ctx, `INSERT INTO authz.models (app, model) VALUES ($1, $2::jsonb)
		ON CONFLICT (app) DO UPDATE SET model = EXCLUDED.model, updated_at = now()`, app, string(raw))
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}

const droppedSQL = `
SELECT DISTINCT t.object_type || '#' || t.relation
  FROM authz.tuples t
 WHERE t.app = $1
   AND NOT EXISTS (SELECT 1 FROM unnest($2::text[], $3::text[]) m(object_type, relation)
                    WHERE m.object_type = t.object_type AND m.relation = t.relation)
 ORDER BY 1
 LIMIT 50`

// droppedRelations lists "<type>#<relation>" pairs that have tuples under app
// but are not relations of model. Caveat: it scans the app's tuples once, so it
// costs tens of ms per 100k rows; PUT model is an admin action, not a hot path.
func droppedRelations(ctx context.Context, tx pgx.Tx, app string, m *Model) ([]string, error) {
	var types, rels []string
	for _, tn := range sortedKeys(m.Types) {
		for _, rn := range sortedKeys(m.Types[tn].Relations) {
			types, rels = append(types, tn), append(rels, rn)
		}
	}
	rows, err := tx.Query(ctx, droppedSQL, app, types, rels)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var pair string
		if err := rows.Scan(&pair); err != nil {
			return nil, err
		}
		out = append(out, pair)
	}
	return out, rows.Err()
}
