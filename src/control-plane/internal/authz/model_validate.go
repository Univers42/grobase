package authz

import (
	"errors"
	"fmt"
	"sort"
)

// Limits on model size: they bound parse cost and the work one check can fan out to.
const (
	maxTypes        = 100
	maxNamesPerType = 100
)

func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalidModel, fmt.Sprintf(format, a...))
}

func (m *Model) validate() error {
	if len(m.Types) == 0 || len(m.Types) > maxTypes {
		return invalid("a model needs 1 to %d types", maxTypes)
	}
	for _, name := range sortedKeys(m.Types) {
		if err := m.validateType(name, m.Types[name]); err != nil {
			return err
		}
	}
	return nil
}

func (m *Model) validateType(name string, t *TypeDef) error {
	if name == UserType || !ValidName(name) {
		return invalid("type name %q is invalid or reserved", name)
	}
	if len(t.Relations)+len(t.Permissions) > maxNamesPerType {
		return invalid("type %s has more than %d relations and permissions", name, maxNamesPerType)
	}
	for _, rel := range sortedKeys(t.Relations) {
		if err := m.validateRelation(name, rel, t); err != nil {
			return err
		}
	}
	for _, perm := range sortedKeys(t.Permissions) {
		if err := m.validatePermission(name, perm, t); err != nil {
			return err
		}
	}
	return nil
}

func (m *Model) validateRelation(typ, rel string, t *TypeDef) error {
	if !ValidName(rel) {
		return invalid("%s: relation name %q is invalid", typ, rel)
	}
	if _, clash := t.Permissions[rel]; clash {
		return invalid("%s: %q is both a relation and a permission", typ, rel)
	}
	for _, st := range t.Relations[rel] {
		if err := m.validateSubjectType(st); err != nil {
			return invalid("%s.%s: %v", typ, rel, err)
		}
	}
	return nil
}

func (m *Model) validateSubjectType(st SubjectType) error {
	if st.Type == UserType {
		if st.Relation != "" {
			return errors.New("user takes no relation")
		}
		return nil
	}
	target, ok := m.Types[st.Type]
	if !ok {
		return fmt.Errorf("unknown type %q", st.Type)
	}
	if st.Relation != "" && !target.has(st.Relation) {
		return fmt.Errorf("type %q has no %q", st.Type, st.Relation)
	}
	return nil
}

func (t *TypeDef) has(name string) bool {
	_, rel := t.Relations[name]
	_, perm := t.Permissions[name]
	return rel || perm
}

func (m *Model) validatePermission(typ, perm string, t *TypeDef) error {
	if !ValidName(perm) {
		return invalid("%s: permission name %q is invalid", typ, perm)
	}
	if err := m.validateExpr(t.Permissions[perm], t); err != nil {
		return invalid("%s.%s: %v", typ, perm, err)
	}
	return nil
}

func (m *Model) validateExpr(e *Expr, t *TypeDef) error {
	switch e.Kind {
	case kindRelation:
		if _, ok := t.Relations[e.Name]; !ok {
			return fmt.Errorf("relation %q is not defined", e.Name)
		}
	case kindPermission:
		if !t.has(e.Name) {
			return fmt.Errorf("permission %q is not defined", e.Name)
		}
	case kindFrom:
		return m.validateFrom(e, t)
	case kindUnion:
		return m.validateAll(e.Children, t)
	case kindExclude:
		return m.validateExclude(e, t)
	}
	return nil
}

func (m *Model) validateAll(items []*Expr, t *TypeDef) error {
	for _, c := range items {
		if err := m.validateExpr(c, t); err != nil {
			return err
		}
	}
	return nil
}

// validateFrom requires the tupleset relation to name plain objects whose
// types all define the followed name, else the walk could not continue.
func (m *Model) validateFrom(e *Expr, t *TypeDef) error {
	sts, ok := t.Relations[e.From]
	if !ok {
		return fmt.Errorf("tupleset relation %q is not defined", e.From)
	}
	followed := 0
	for _, st := range sts {
		if st.Type == UserType || st.Relation != "" {
			continue
		}
		followed++
		if !m.Types[st.Type].has(e.Name) {
			return fmt.Errorf("%q is followed to type %q, which has no %q", e.From, st.Type, e.Name)
		}
	}
	if followed == 0 {
		return fmt.Errorf("tupleset relation %q names no object type to follow", e.From)
	}
	return nil
}

// validateExclude holds the minus to concrete users: a userset or wildcard in
// a minus can never be answered per user, so the model may not declare one.
func (m *Model) validateExclude(e *Expr, t *TypeDef) error {
	sts, ok := t.Relations[e.Minus]
	if !ok {
		return fmt.Errorf("minus relation %q is not defined", e.Minus)
	}
	for _, st := range sts {
		if st.Type != UserType || st.Wildcard {
			return fmt.Errorf("minus relation %q may list only \"user\"", e.Minus)
		}
	}
	return m.validateExpr(e.Base, t)
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
