package authz

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

// ErrInvalidTuples wraps every tuple-write validation failure (HTTP 400).
var ErrInvalidTuples = errors.New("invalid authz tuples")

// MaxTuplesPerWrite bounds one replace_source_tuples call.
const MaxTuplesPerWrite = 1000

var sourceRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$`)

// TupleIn is one wire tuple: the object comes from the request.
type TupleIn struct {
	Relation string `json:"relation"`
	Subject  string `json:"subject"`
}

// TuplesRequest replaces the tuples one source owns on one object.
type TuplesRequest struct {
	Source string    `json:"source"`
	Object string    `json:"object"`
	Tuples []TupleIn `json:"tuples"`
}

// Prepared is a validated TuplesRequest, ready for authz.replace_source_tuples.
type Prepared struct {
	Object Ref
	Source string
	JSON   []byte
}

type primitiveTuple struct {
	Relation        string `json:"relation"`
	SubjectType     string `json:"subject_type"`
	SubjectID       string `json:"subject_id"`
	SubjectRelation string `json:"subject_relation,omitempty"`
}

func badTuples(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalidTuples, fmt.Sprintf(format, a...))
}

// PrepareTuples checks req against the model: the object type exists, every
// relation is a relation (not a permission) of it, and every subject has a
// form that relation lists. An empty tuple list is valid and removes the pair.
func (m *Model) PrepareTuples(req TuplesRequest) (Prepared, error) {
	if !sourceRe.MatchString(req.Source) {
		return Prepared{}, badTuples("source must match %s", sourceRe)
	}
	if len(req.Tuples) > MaxTuplesPerWrite {
		return Prepared{}, badTuples("at most %d tuples per request", MaxTuplesPerWrite)
	}
	obj, err := ParseRef(req.Object)
	if err != nil {
		return Prepared{}, badTuples("%v", err)
	}
	def, ok := m.Types[obj.Type]
	if !ok {
		return Prepared{}, badTuples("type %q is not in the model", obj.Type)
	}
	rows, err := def.convert(req.Tuples)
	if err != nil {
		return Prepared{}, err
	}
	body, err := json.Marshal(rows)
	if err != nil {
		return Prepared{}, badTuples("%v", err)
	}
	return Prepared{Object: obj, Source: req.Source, JSON: body}, nil
}

func (t *TypeDef) convert(in []TupleIn) ([]primitiveTuple, error) {
	seen := make(map[TupleIn]struct{}, len(in))
	out := make([]primitiveTuple, 0, len(in))
	for _, tu := range in {
		if _, dup := seen[tu]; dup {
			continue
		}
		seen[tu] = struct{}{}
		row, err := t.convertOne(tu)
		if err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, nil
}

func (t *TypeDef) convertOne(tu TupleIn) (primitiveTuple, error) {
	allowed, ok := t.Relations[tu.Relation]
	if !ok {
		return primitiveTuple{}, badTuples("%q is not a relation of this type", tu.Relation)
	}
	sub, err := ParseSubject(tu.Subject)
	if err != nil {
		return primitiveTuple{}, badTuples("%v", err)
	}
	for _, st := range allowed {
		if st.permits(sub) {
			return primitiveTuple{tu.Relation, sub.Type, sub.ID, sub.Relation}, nil
		}
	}
	return primitiveTuple{}, badTuples("relation %q does not accept subject %q", tu.Relation, tu.Subject)
}

// permits reports whether a relation entry admits the subject: the plain
// "user" entry admits user ids but never the wildcard, which needs "user:*".
func (st SubjectType) permits(s Subject) bool {
	switch {
	case st.Type != s.Type:
		return false
	case s.IsWildcard():
		return st.Wildcard
	case st.Wildcard:
		return false
	}
	return st.Relation == s.Relation
}
