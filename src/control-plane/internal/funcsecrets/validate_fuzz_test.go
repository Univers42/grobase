package funcsecrets

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// keyPatternMirror is the exact grammar SetRequest.Validate compiles:
//
//	[A-Za-z_][A-Za-z0-9_]{0,127}  (env-var style, 1..128 chars)
const keyPatternMirror = `^[A-Za-z_][A-Za-z0-9_]{0,127}$`

func TestSetRequestValidate_Boundaries(t *testing.T) {
	cases := []struct {
		name string
		key  string
		ok   bool
	}{
		{"single letter", "A", true},
		{"single underscore", "_", true},
		{"exactly 128", "A" + strings.Repeat("b", 127), true},
		{"129 too long", "A" + strings.Repeat("b", 128), false},
		{"empty", "", false},
		{"leading digit rejected", "1KEY", false},
		{"dash rejected", "A-B", false},
		{"dot rejected", "A.B", false},
		{"space rejected", "A B", false},
		{"NUL rejected", "A\x00B", false},
		{"newline rejected", "A\nB", false},
		{"unicode rejected", "Aé", false},
		{"trailing digit ok", "K9", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := SetRequest{Key: c.key}.Validate()
			if c.ok && err != nil {
				t.Fatalf("key=%q: want accept, got %v", c.key, err)
			}
			if !c.ok && err == nil {
				t.Fatalf("key=%q: want reject, got nil", c.key)
			}
		})
	}
}

// FuzzSetRequestValidate: never panics; parity with recompiling the key grammar.
// Value/FunctionName are irrelevant to Validate (only Key is checked) — so the
// fuzzed Key fully determines the decision.
func FuzzSetRequestValidate(f *testing.F) {
	for _, s := range []string{
		"API_KEY", "_x", "a", "", "1KEY", "has space",
		"has-dash", "weird$", "a.b", "A\x00", "é", strings.Repeat("z", 128), strings.Repeat("z", 129),
	} {
		f.Add(s)
	}
	re := regexp.MustCompile(keyPatternMirror)
	f.Fuzz(func(t *testing.T, key string) {
		err := SetRequest{Key: key, Value: "v", FunctionName: "fn"}.Validate()
		want := re.MatchString(key)
		if want && err != nil {
			t.Fatalf("regex accepts %q but Validate rejected: %v", key, err)
		}
		if !want && err == nil {
			t.Fatalf("regex rejects %q but Validate accepted", key)
		}
	})
}

func TestFuncsecretsConstErrorParity(t *testing.T) {
	if ErrNotFound.Error() != "function secret not found" {
		t.Fatalf("Error() = %q", ErrNotFound.Error())
	}
	if !errors.Is(fmt.Errorf("ctx: %w", ErrNotFound), ErrNotFound) {
		t.Fatal("errors.Is(wrap, ErrNotFound) = false")
	}
}
