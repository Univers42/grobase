package authz

import (
	"errors"
	"strings"
	"testing"
)

func TestParseModelAccepts(t *testing.T) {
	if _, err := ParseModel([]byte(pageModel)); err != nil {
		t.Fatal(err)
	}
	// A cyclic permission definition is legal: evaluation bounds it.
	cyc := `{"types":{"t":{"relations":{"o":{"types":["user"]}},"permissions":{
	  "a":{"permission":"b"},"b":{"union":[{"permission":"a"},{"relation":"o"}]}}}}}`
	if _, err := ParseModel([]byte(cyc)); err != nil {
		t.Fatalf("cycle: %v", err)
	}
}

func TestParseModelRejects(t *testing.T) {
	rel := `"relations":{"o":{"types":["user"]},"p":{"types":["t"]},"w":{"types":["user:*"]}}`
	cases := map[string]string{
		"unknown top key":      `{"types":{"t":{}},"extra":1}`,
		"unknown type key":     `{"types":{"t":{"relation":{}}}}`,
		"unknown relation key": `{"types":{"t":{"relations":{"o":{"types":["user"],"x":1}}}}}`,
		"unknown expr key":     `{"types":{"t":{` + rel + `,"permissions":{"a":{"relation":"o","x":1}}}}}`,
		"two expr forms":       `{"types":{"t":{` + rel + `,"permissions":{"a":{"relation":"o","permission":"a"}}}}}`,
		"empty union":          `{"types":{"t":{` + rel + `,"permissions":{"a":{"union":[]}}}}}`,
		"unknown relation ref": `{"types":{"t":{` + rel + `,"permissions":{"a":{"relation":"zz"}}}}}`,
		"unknown permission":   `{"types":{"t":{` + rel + `,"permissions":{"a":{"permission":"zz"}}}}}`,
		"unknown subject type": `{"types":{"t":{"relations":{"o":{"types":["ghost"]}}}}}`,
		"unknown userset rel":  `{"types":{"t":{"relations":{"o":{"types":["t#nope"]}}}}}`,
		"empty types":          `{"types":{"t":{"relations":{"o":{"types":[]}}}}}`,
		"user as a type":       `{"types":{"user":{}}}`,
		"bad type name":        `{"types":{"Bad":{}}}`,
		"name clash":           `{"types":{"t":{` + rel + `,"permissions":{"o":{"relation":"o"}}}}}`,
		"from needs objects":   `{"types":{"t":{` + rel + `,"permissions":{"a":{"from":"o","permission":"a"}}}}}`,
		"from missing name":    `{"types":{"t":{` + rel + `,"permissions":{"a":{"from":"p","permission":"zz"}}}}}`,
		"minus with userset":   `{"types":{"w":{"relations":{"m":{"types":["user"]}}},"t":{"relations":{"o":{"types":["user"]},"b":{"types":["w#m"]}},"permissions":{"a":{"exclude":{"base":{"relation":"o"},"minus":{"relation":"b"}}}}}}}`,
		"minus with wildcard":  `{"types":{"t":{"relations":{"o":{"types":["user"]},"b":{"types":["user","user:*"]}},"permissions":{"a":{"exclude":{"base":{"relation":"o"},"minus":{"relation":"b"}}}}}}}`,
		"minus unknown key":    `{"types":{"t":{"relations":{"o":{"types":["user"]},"b":{"types":["user"]}},"permissions":{"a":{"exclude":{"base":{"relation":"o"},"minus":{"relation":"b","x":1}}}}}}}`,
		"trailing data":        pageModel + ` {}`,
		"no types":             `{"types":{}}`,
		"not json":             `nope`,
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := ParseModel([]byte(doc))
			if !errors.Is(err, ErrInvalidModel) {
				t.Fatalf("got %v, want ErrInvalidModel", err)
			}
		})
	}
}

func TestParseModelDepthLimit(t *testing.T) {
	expr := `{"relation":"o"}`
	for i := 0; i < maxExprDepth+1; i++ {
		expr = `{"union":[` + expr + `]}`
	}
	doc := `{"types":{"t":{"relations":{"o":{"types":["user"]}},"permissions":{"a":` + expr + `}}}}`
	if _, err := ParseModel([]byte(doc)); err == nil || !strings.Contains(err.Error(), "nests deeper") {
		t.Fatalf("got %v, want a nesting error", err)
	}
}

func TestParseSubjectAndRef(t *testing.T) {
	good := map[string]Subject{
		"user:abc":            {"user", "abc", ""},
		"user:*":              {"user", "*", ""},
		"page:1":              {"page", "1", ""},
		"workspace:w:1#admin": {"workspace", "w:1", "admin"},
	}
	for in, want := range good {
		if got, err := ParseSubject(in); err != nil || got != want {
			t.Errorf("ParseSubject(%q) = %+v, %v", in, got, err)
		}
	}
	for _, in := range []string{"", "user", "user:", "User:a", "user:a#r", "page:*", "page:*#r", "w:a#", "w:a#B", "w:a b#c\x00", "w:" + strings.Repeat("x", 257)} {
		if _, err := ParseSubject(in); err == nil {
			t.Errorf("ParseSubject(%q) accepted", in)
		}
	}
	if _, err := ParseRef("user:*"); err == nil {
		t.Error("ParseRef accepted a wildcard object")
	}
	if r, err := ParseRef("page:a:b"); err != nil || r.ID != "a:b" {
		t.Errorf("ParseRef(page:a:b) = %+v, %v", r, err)
	}
}
