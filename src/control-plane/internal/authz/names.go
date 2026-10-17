// Package authz evaluates relationship-based access checks over authz.tuples.
//
// The store is Postgres, the evaluator is Go: a request prefetches the tuples
// it needs level by level inside one REPEATABLE READ READ ONLY transaction and
// evaluates the model in memory. There is no cross-request cache, so a revoke
// that has committed is visible to the next check.
package authz

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// UserType is the one built-in subject type; a model may not define it.
const UserType = "user"

// Wildcard is the subject id of "user:*".
const Wildcard = "*"

const maxIDLen = 256

var nameRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,62}$`)

// ErrInvalidName reports a type, relation or id that breaks the string forms.
var ErrInvalidName = errors.New("invalid authz name")

// Ref names one object: "<type>:<id>".
type Ref struct{ Type, ID string }

func (r Ref) String() string { return r.Type + ":" + r.ID }

// Subject is a tuple subject: a user ("user:<id>"), the wildcard ("user:*"),
// a plain object ("<type>:<id>") or a userset ("<type>:<id>#<relation>").
type Subject struct{ Type, ID, Relation string }

// IsWildcard reports whether s is "user:*".
func (s Subject) IsWildcard() bool { return s.Type == UserType && s.ID == Wildcard }

func (s Subject) String() string {
	out := s.Type + ":" + s.ID
	if s.Relation != "" {
		out += "#" + s.Relation
	}
	return out
}

// ValidName reports whether s is a legal type or relation name.
func ValidName(s string) bool { return nameRe.MatchString(s) }

func validID(id string) bool {
	return id != "" && len(id) <= maxIDLen && !strings.ContainsAny(id, "#\x00")
}

func splitTypeID(s string) (typ, id string, err error) {
	typ, id, found := strings.Cut(s, ":")
	if !found || !ValidName(typ) || !validID(id) {
		return "", "", fmt.Errorf("%w: %q is not <type>:<id>", ErrInvalidName, s)
	}
	return typ, id, nil
}

// ParseRef parses "<type>:<id>". The wildcard id is reserved for user subjects.
func ParseRef(s string) (Ref, error) {
	typ, id, err := splitTypeID(s)
	if err != nil {
		return Ref{}, err
	}
	if id == Wildcard {
		return Ref{}, fmt.Errorf("%w: %q uses the wildcard id on an object", ErrInvalidName, s)
	}
	return Ref{Type: typ, ID: id}, nil
}

// ParseSubject parses the three subject forms. A wildcard belongs to "user"
// only, and "user" carries no relation.
func ParseSubject(s string) (Subject, error) {
	base, rel, hasRel := strings.Cut(s, "#")
	typ, id, err := splitTypeID(base)
	if err != nil {
		return Subject{}, fmt.Errorf("%w: subject %q", ErrInvalidName, s)
	}
	if hasRel && !ValidName(rel) {
		return Subject{}, fmt.Errorf("%w: subject %q has a bad relation", ErrInvalidName, s)
	}
	sub := Subject{Type: typ, ID: id, Relation: rel}
	if id == Wildcard && (typ != UserType || hasRel) {
		return Subject{}, fmt.Errorf("%w: subject %q misuses the wildcard", ErrInvalidName, s)
	}
	if typ == UserType && hasRel {
		return Subject{}, fmt.Errorf("%w: subject %q: a user has no relation", ErrInvalidName, s)
	}
	return sub, nil
}
