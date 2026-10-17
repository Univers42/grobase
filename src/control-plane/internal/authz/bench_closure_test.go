//go:build authz_bench

package authz

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// closureSQL is the one-statement alternative to the level-by-level frontier:
// a recursive CTE walks every tuple edge reachable from the roots, then all
// their tuples come back in one result. UNION (not UNION ALL) deduplicates, so
// cycles and diamonds terminate.
const closureSQL = `
WITH RECURSIVE reach(object_type, object_id) AS (
  SELECT * FROM unnest($2::text[], $3::text[])
  UNION
  SELECT t.subject_type, t.subject_id
    FROM reach r
    JOIN authz.tuples t ON t.app = $1 AND t.object_type = r.object_type AND t.object_id = r.object_id
)
SELECT DISTINCT t.object_type, t.object_id, t.relation, t.subject_type, t.subject_id, t.subject_relation
  FROM reach r
  JOIN authz.tuples t ON t.app = $1 AND t.object_type = r.object_type AND t.object_id = r.object_id
 LIMIT $4`

// closureSource answers every Load from the closure fetched on the first one.
// Caveat: bench-only. It follows every subject edge whatever the model says,
// so it loads more rows than the level strategy, and it has no hop cap (the
// evaluator still caps depth at 16).
type closureSource struct {
	tx     pgx.Tx
	app    string
	loaded bool
	byWant map[Want][]Tuple
}

func (c *closureSource) Load(ctx context.Context, wants []Want, maxRows int) ([]Tuple, error) {
	if !c.loaded {
		if err := c.fetch(ctx, wants, maxRows); err != nil {
			return nil, err
		}
	}
	var out []Tuple
	for _, w := range wants {
		out = append(out, c.byWant[w]...)
	}
	return out, nil
}

func (c *closureSource) fetch(ctx context.Context, wants []Want, maxRows int) error {
	types, ids, _ := splitWants(wants)
	rows, err := c.tx.Query(ctx, closureSQL, c.app, types, ids, maxRows+1)
	if err != nil {
		return err
	}
	defer rows.Close()
	c.byWant = map[Want][]Tuple{}
	n := 0
	for rows.Next() {
		var t Tuple
		if err := rows.Scan(&t.ObjType, &t.ObjID, &t.Relation, &t.Subject.Type, &t.Subject.ID, &t.Subject.Relation); err != nil {
			return err
		}
		c.byWant[t.Want] = append(c.byWant[t.Want], t)
		n++
	}
	if n > maxRows {
		return ErrRowBudget
	}
	c.loaded = true
	return rows.Err()
}

// checkClosure is Store.Check with the closure prefetch, for the m232 comparison.
func checkClosure(ctx context.Context, s *Store, q Query) ([]Decision, error) {
	tx, err := s.db.BeginTxOpts(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	model, err := readModel(ctx, tx, q.App)
	if err != nil {
		return nil, err
	}
	ev := &Evaluator{Model: model, Limits: s.cfg.Limits, Log: s.log}
	return ev.Check(ctx, &closureSource{tx: tx, app: q.App}, q)
}
