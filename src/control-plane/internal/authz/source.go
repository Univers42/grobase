package authz

import "context"

// Want names the direct tuples of one relation on one object: the unit a
// prefetch loads and the unit the evaluator records as missing.
type Want struct{ ObjType, ObjID, Relation string }

// Tuple is one stored row. Several sources may store the same logical tuple;
// a Source returns each logical tuple once.
type Tuple struct {
	Want
	Subject Subject
}

// Source loads the tuples of the wanted (object, relation) pairs from one
// consistent snapshot. At most maxRows rows may come back; one more means the
// request exceeded its row budget and the Source returns ErrRowBudget.
type Source interface {
	Load(ctx context.Context, wants []Want, maxRows int) ([]Tuple, error)
}

// tupleIndex is the request-local view of everything loaded so far.
type tupleIndex struct {
	loaded   map[Want]struct{}
	subjects map[Want][]Subject
	rows     int
}

func newTupleIndex() *tupleIndex {
	return &tupleIndex{loaded: map[Want]struct{}{}, subjects: map[Want][]Subject{}}
}

// add records a fetched batch. A want that returned no row is still loaded:
// "known empty" is different from "not fetched yet".
func (ix *tupleIndex) add(wants []Want, rows []Tuple) {
	for _, w := range wants {
		ix.loaded[w] = struct{}{}
	}
	for _, t := range rows {
		ix.subjects[t.Want] = append(ix.subjects[t.Want], t.Subject)
	}
	ix.rows += len(rows)
}

func (ix *tupleIndex) isLoaded(w Want) bool {
	_, ok := ix.loaded[w]
	return ok
}
