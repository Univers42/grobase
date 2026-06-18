package jsoncanon

import "testing"

func TestCanonicalJSON(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"empty -> {}", "", "{}"},
		{"invalid -> {}", "not json", "{}"},
		{"keys sorted", `{"b":1,"a":2}`, `{"a":2,"b":1}`},
		{"nested keys sorted", `{"z":{"y":1,"x":2}}`, `{"z":{"x":2,"y":1}}`},
		{"objects inside arrays sorted", `[{"b":1,"a":2}]`, `[{"a":2,"b":1}]`},
		{"whitespace insignificant", "{ \"a\" : 1 }", `{"a":1}`},
		{"scalar passthrough", `5`, `5`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := string(CanonicalJSON([]byte(c.in))); got != c.want {
				t.Fatalf("CanonicalJSON(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// TestCanonicalJSONStable asserts the canonical form is order-independent: two
// key-permuted encodings of the same object hash to identical bytes (the audit
// chain depends on this).
func TestCanonicalJSONStable(t *testing.T) {
	a := CanonicalJSON([]byte(`{"a":1,"b":{"c":2,"d":3}}`))
	b := CanonicalJSON([]byte(`{"b":{"d":3,"c":2},"a":1}`))
	if string(a) != string(b) {
		t.Fatalf("canonical form not order-independent: %q vs %q", a, b)
	}
}

// FuzzCanonicalJSON asserts it never panics and is idempotent on valid JSON
// (canonicalizing a canonical form is a no-op).
func FuzzCanonicalJSON(f *testing.F) {
	f.Add([]byte(`{"b":1,"a":[{"y":1,"x":2}]}`))
	f.Add([]byte(``))
	f.Add([]byte(`null`))
	f.Add([]byte(`[1,2,3]`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		once := CanonicalJSON(raw)
		twice := CanonicalJSON(once)
		if string(once) != string(twice) {
			t.Fatalf("not idempotent: %q -> %q -> %q", raw, once, twice)
		}
	})
}
