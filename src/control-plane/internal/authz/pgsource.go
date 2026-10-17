package authz

import (
	"context"
	_ "embed"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// FrontierSQL is the query behind Source.Load; the perf gate reads the same
// text, so the plan it asserts is the plan production runs.
//
//go:embed frontier.sql
var FrontierSQL string

type queryer interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// pgSource loads tuples of one app inside the caller's transaction, so every
// Load of a request sees the same snapshot.
type pgSource struct {
	q   queryer
	app string
}

// Load runs one frontier query. It asks for maxRows+1 rows to tell "exactly at
// the budget" from "over it".
func (s pgSource) Load(ctx context.Context, wants []Want, maxRows int) ([]Tuple, error) {
	types, ids, rels := splitWants(wants)
	rows, err := s.q.Query(ctx, FrontierSQL, s.app, types, ids, rels, maxRows+1)
	if err != nil {
		return nil, fmt.Errorf("authz frontier: %w", err)
	}
	defer rows.Close()
	out := make([]Tuple, 0, len(wants))
	for rows.Next() {
		var t Tuple
		if err := rows.Scan(&t.ObjType, &t.ObjID, &t.Relation, &t.Subject.Type, &t.Subject.ID, &t.Subject.Relation); err != nil {
			return nil, fmt.Errorf("authz frontier scan: %w", err)
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("authz frontier: %w", err)
	}
	if len(out) > maxRows {
		return nil, ErrRowBudget
	}
	return out, nil
}

func splitWants(wants []Want) (types, ids, rels []string) {
	types = make([]string, len(wants))
	ids = make([]string, len(wants))
	rels = make([]string, len(wants))
	for i, w := range wants {
		types[i], ids[i], rels[i] = w.ObjType, w.ObjID, w.Relation
	}
	return types, ids, rels
}
