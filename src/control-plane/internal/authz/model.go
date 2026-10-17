package authz

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// ErrInvalidModel wraps every model parse or validation failure.
var ErrInvalidModel = errors.New("invalid authz model")

// Expression kinds. There is no intersection: nothing needs it today.
const (
	kindRelation   = "relation"   // direct tuples of this object
	kindPermission = "permission" // same object, another permission or relation
	kindFrom       = "from"       // tuple-to-userset through a parent relation
	kindUnion      = "union"
	kindExclude    = "exclude"
)

// Expr is one parsed permission expression.
type Expr struct {
	Kind     string
	Name     string // relation, or permission for kindPermission / kindFrom
	From     string // tupleset relation for kindFrom
	Children []*Expr
	Base     *Expr // kindExclude
	Minus    string
}

// SubjectType is one entry of a relation's "types": "user", "user:*", "T" or "T#r".
type SubjectType struct {
	Type     string
	Wildcard bool
	Relation string
}

// TypeDef holds the relations and permissions of one object type.
type TypeDef struct {
	Relations   map[string][]SubjectType
	Permissions map[string]*Expr
	relationAs  map[string]*Expr // a relation read as an expression, built once
}

// Model is a parsed, validated authorization model.
type Model struct{ Types map[string]*TypeDef }

type modelJSON struct {
	Types map[string]typeJSON `json:"types"`
}

type typeJSON struct {
	Relations   map[string]relationJSON    `json:"relations"`
	Permissions map[string]json.RawMessage `json:"permissions"`
}

type relationJSON struct {
	Types []string `json:"types"`
}

type exprJSON struct {
	Relation   *string            `json:"relation"`
	Permission *string            `json:"permission"`
	From       *string            `json:"from"`
	Union      *[]json.RawMessage `json:"union"`
	Exclude    *excludeJSON       `json:"exclude"`
}

type excludeJSON struct {
	Base  json.RawMessage `json:"base"`
	Minus json.RawMessage `json:"minus"`
}

type minusJSON struct {
	Relation *string `json:"relation"`
}

// strictDecode rejects unknown keys and trailing data: a typo in a model must
// fail loudly, not silently drop a rule.
func strictDecode(raw []byte, dst any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidModel, err)
	}
	if dec.More() {
		return fmt.Errorf("%w: trailing data after the JSON value", ErrInvalidModel)
	}
	return nil
}

// ParseModel decodes and validates a model document.
func ParseModel(raw []byte) (*Model, error) {
	var doc modelJSON
	if err := strictDecode(raw, &doc); err != nil {
		return nil, err
	}
	m := &Model{Types: make(map[string]*TypeDef, len(doc.Types))}
	for name, t := range doc.Types {
		def, err := buildType(name, t)
		if err != nil {
			return nil, err
		}
		m.Types[name] = def
	}
	if err := m.validate(); err != nil {
		return nil, err
	}
	return m, nil
}

func buildType(name string, t typeJSON) (*TypeDef, error) {
	def := &TypeDef{
		Relations:   make(map[string][]SubjectType, len(t.Relations)),
		Permissions: make(map[string]*Expr, len(t.Permissions)),
		relationAs:  make(map[string]*Expr, len(t.Relations)),
	}
	for rel, r := range t.Relations {
		sts, err := parseSubjectTypes(r.Types)
		if err != nil {
			return nil, fmt.Errorf("%w: %s.%s: %v", ErrInvalidModel, name, rel, err)
		}
		def.Relations[rel] = sts
		def.relationAs[rel] = &Expr{Kind: kindRelation, Name: rel}
	}
	for perm, raw := range t.Permissions {
		e, err := parseExpr(raw, 1)
		if err != nil {
			return nil, fmt.Errorf("%w: %s.%s: %v", ErrInvalidModel, name, perm, err)
		}
		def.Permissions[perm] = e
	}
	return def, nil
}

// maxExprDepth bounds nesting so a hostile model cannot blow the parser stack.
const maxExprDepth = 16

func parseExpr(raw json.RawMessage, depth int) (*Expr, error) {
	if depth > maxExprDepth {
		return nil, fmt.Errorf("expression nests deeper than %d", maxExprDepth)
	}
	var j exprJSON
	if err := strictDecode(raw, &j); err != nil {
		return nil, err
	}
	switch {
	case j.Union != nil && j.Relation == nil && j.Permission == nil && j.From == nil && j.Exclude == nil:
		return parseUnion(*j.Union, depth)
	case j.Exclude != nil && j.Relation == nil && j.Permission == nil && j.From == nil && j.Union == nil:
		return parseExclude(j.Exclude, depth)
	case j.Relation != nil && j.Permission == nil && j.From == nil && j.Union == nil && j.Exclude == nil:
		return &Expr{Kind: kindRelation, Name: *j.Relation}, nil
	case j.Permission != nil && j.Relation == nil && j.Union == nil && j.Exclude == nil:
		return parsePermission(j), nil
	}
	return nil, errors.New("an expression takes exactly one of relation, permission, from+permission, union, exclude")
}

func parsePermission(j exprJSON) *Expr {
	if j.From != nil {
		return &Expr{Kind: kindFrom, From: *j.From, Name: *j.Permission}
	}
	return &Expr{Kind: kindPermission, Name: *j.Permission}
}

func parseUnion(items []json.RawMessage, depth int) (*Expr, error) {
	if len(items) == 0 {
		return nil, errors.New("union needs at least one branch")
	}
	e := &Expr{Kind: kindUnion, Children: make([]*Expr, 0, len(items))}
	for _, it := range items {
		c, err := parseExpr(it, depth+1)
		if err != nil {
			return nil, err
		}
		e.Children = append(e.Children, c)
	}
	return e, nil
}

func parseExclude(x *excludeJSON, depth int) (*Expr, error) {
	if len(x.Base) == 0 || len(x.Minus) == 0 {
		return nil, errors.New("exclude needs base and minus")
	}
	base, err := parseExpr(x.Base, depth+1)
	if err != nil {
		return nil, err
	}
	var minus minusJSON
	if err := strictDecode(x.Minus, &minus); err != nil {
		return nil, err
	}
	if minus.Relation == nil {
		return nil, errors.New("exclude.minus must be {\"relation\": r}")
	}
	return &Expr{Kind: kindExclude, Base: base, Minus: *minus.Relation}, nil
}

func parseSubjectTypes(items []string) ([]SubjectType, error) {
	if len(items) == 0 {
		return nil, errors.New("types must not be empty")
	}
	out := make([]SubjectType, 0, len(items))
	for _, s := range items {
		st, err := parseSubjectType(s)
		if err != nil {
			return nil, err
		}
		out = append(out, st)
	}
	return out, nil
}

// parseSubjectType reads "user", "user:*", "T" or "T#r".
func parseSubjectType(s string) (SubjectType, error) {
	if s == UserType {
		return SubjectType{Type: UserType}, nil
	}
	if s == UserType+":"+Wildcard {
		return SubjectType{Type: UserType, Wildcard: true}, nil
	}
	typ, rel, hasRel := strings.Cut(s, "#")
	if !ValidName(typ) || (hasRel && !ValidName(rel)) {
		return SubjectType{}, fmt.Errorf("bad subject type %q", s)
	}
	return SubjectType{Type: typ, Relation: rel}, nil
}

// lookup returns the expression behind a permission or relation name.
func (m *Model) lookup(typ, name string) (*Expr, bool) {
	t, ok := m.Types[typ]
	if !ok {
		return nil, false
	}
	if e, ok := t.Permissions[name]; ok {
		return e, true
	}
	e, ok := t.relationAs[name]
	return e, ok
}
