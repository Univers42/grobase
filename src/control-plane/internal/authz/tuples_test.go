package authz

import (
	"errors"
	"testing"
)

func TestPrepareTuples(t *testing.T) {
	m := mustModel(t, pageModel)
	ok := TuplesRequest{Source: "page_row", Object: "page:1", Tuples: []TupleIn{
		{"owner", "user:alice"},
		{"owner", "user:alice"},
		{"viewer", "user:*"},
		{"viewer", "workspace:w#member"},
		{"parent", "page:0"},
	}}
	p, err := m.PrepareTuples(ok)
	if err != nil {
		t.Fatal(err)
	}
	want := `[{"relation":"owner","subject_type":"user","subject_id":"alice"},` +
		`{"relation":"viewer","subject_type":"user","subject_id":"*"},` +
		`{"relation":"viewer","subject_type":"workspace","subject_id":"w","subject_relation":"member"},` +
		`{"relation":"parent","subject_type":"page","subject_id":"0"}]`
	if string(p.JSON) != want {
		t.Fatalf("got %s\nwant %s", p.JSON, want)
	}
	if _, err := m.PrepareTuples(TuplesRequest{Source: "s", Object: "page:1"}); err != nil {
		t.Fatalf("an empty list removes the pair: %v", err)
	}
}

func TestPrepareTuplesRejects(t *testing.T) {
	m := mustModel(t, pageModel)
	one := func(rel, sub string) TuplesRequest {
		return TuplesRequest{Source: "s", Object: "page:1", Tuples: []TupleIn{{rel, sub}}}
	}
	cases := map[string]TuplesRequest{
		"bad source":                 {Source: "a b", Object: "page:1"},
		"empty source":               {Object: "page:1"},
		"unknown type":               {Source: "s", Object: "ghost:1"},
		"bad object":                 {Source: "s", Object: "page"},
		"wildcard object":            {Source: "s", Object: "page:*"},
		"permission is not writable": one("read", "user:a"),
		"unknown relation":           one("zz", "user:a"),
		"wildcard where user only":   one("owner", "user:*"),
		"wrong subject type":         one("owner", "page:1"),
		"userset not listed":         one("owner", "workspace:w#member"),
		"wrong userset relation":     one("viewer", "workspace:w#admin"),
		"plain object for userset":   one("viewer", "workspace:w"),
		"bad subject":                one("owner", "nope"),
		"too many":                   {Source: "s", Object: "page:1", Tuples: make([]TupleIn, MaxTuplesPerWrite+1)},
	}
	for name, req := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := m.PrepareTuples(req); !errors.Is(err, ErrInvalidTuples) {
				t.Fatalf("got %v, want ErrInvalidTuples", err)
			}
		})
	}
}
