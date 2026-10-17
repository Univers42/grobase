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

// tupleIndex is the request-local view of everything loaded so far. One map
// serves both questions: a key present with no subjects is "known empty", an
// absent key is "not fetched yet" (a second map for that cost 2x the hashing).
type tupleIndex struct {
	subjects map[Want][]Subject
	rows     int
}

// newTupleIndex sizes the map for about four wants per queried object, the
// shape of a page/parent/owner/viewer model, so a large batch does not rehash.
func newTupleIndex(objects int) *tupleIndex {
	return &tupleIndex{subjects: make(map[Want][]Subject, 4*objects)}
}

// add records a fetched batch. A want that returned no row is still loaded.
func (ix *tupleIndex) add(wants []Want, rows []Tuple) {
	for _, w := range wants {
		if _, ok := ix.subjects[w]; !ok {
			ix.subjects[w] = nil
		}
	}
	for _, t := range rows {
		ix.subjects[t.Want] = append(ix.subjects[t.Want], t.Subject)
	}
	ix.rows += len(rows)
}

func (ix *tupleIndex) isLoaded(w Want) bool {
	_, ok := ix.subjects[w]
	return ok
}
