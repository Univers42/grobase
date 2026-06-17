package functriggers

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// funcNamePatternMirror is the exact grammar CreateRequest.Validate compiles for
// function_name: [a-zA-Z][a-zA-Z0-9_-]{0,63}  (1..64 chars, alpha-led).
const funcNamePatternMirror = `^[a-zA-Z][a-zA-Z0-9_-]{0,63}$`

func TestCreateRequestValidate_Boundaries(t *testing.T) {
	base := CreateRequest{Name: "ok", FunctionName: "fn"}
	cases := []struct {
		name string
		mut  func(CreateRequest) CreateRequest
		ok   bool
	}{
		{"baseline ok", func(c CreateRequest) CreateRequest { return c }, true},
		{"name len 1 ok", func(c CreateRequest) CreateRequest { c.Name = "x"; return c }, true},
		{"name len 64 ok", func(c CreateRequest) CreateRequest { c.Name = strings.Repeat("n", 64); return c }, true},
		{"name len 65 rejected", func(c CreateRequest) CreateRequest { c.Name = strings.Repeat("n", 65); return c }, false},
		{"name empty rejected", func(c CreateRequest) CreateRequest { c.Name = ""; return c }, false},
		{"fn leading digit rejected", func(c CreateRequest) CreateRequest { c.FunctionName = "9fn"; return c }, false},
		{"fn 64 ok", func(c CreateRequest) CreateRequest { c.FunctionName = "a" + strings.Repeat("b", 63); return c }, true},
		{"fn 65 rejected", func(c CreateRequest) CreateRequest { c.FunctionName = "a" + strings.Repeat("b", 64); return c }, false},
		{"max_attempts 0 ok", func(c CreateRequest) CreateRequest { c.MaxAttempts = 0; return c }, true},
		{"max_attempts 32 ok", func(c CreateRequest) CreateRequest { c.MaxAttempts = 32; return c }, true},
		{"max_attempts 33 rejected", func(c CreateRequest) CreateRequest { c.MaxAttempts = 33; return c }, false},
		{"max_attempts negative rejected", func(c CreateRequest) CreateRequest { c.MaxAttempts = -1; return c }, false},
		{"timeout 60000 ok", func(c CreateRequest) CreateRequest { c.TimeoutMs = 60000; return c }, true},
		{"timeout 60001 rejected", func(c CreateRequest) CreateRequest { c.TimeoutMs = 60001; return c }, false},
		{"timeout negative rejected", func(c CreateRequest) CreateRequest { c.TimeoutMs = -1; return c }, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := c.mut(base).Validate()
			if c.ok && err != nil {
				t.Fatalf("want accept, got %v", err)
			}
			if !c.ok && err == nil {
				t.Fatalf("want reject, got nil")
			}
		})
	}
}

// FuzzCreateRequestValidate_FunctionName: name + numeric bounds fixed-valid, so
// the function_name regex is the sole gate — parity with recompiling it.
func FuzzCreateRequestValidate_FunctionName(f *testing.F) {
	for _, s := range []string{"fn", "a-b", "a_b", "", "9fn", "has space",
		"A", "z9", "a\x00", "é", strings.Repeat("a", 64), strings.Repeat("a", 65), "a.b"} {
		f.Add(s)
	}
	re := regexp.MustCompile(funcNamePatternMirror)
	f.Fuzz(func(t *testing.T, fn string) {
		err := CreateRequest{Name: "ok", FunctionName: fn}.Validate()
		want := re.MatchString(fn)
		if want && err != nil {
			t.Fatalf("regex accepts fn %q but Validate rejected: %v", fn, err)
		}
		if !want && err == nil {
			t.Fatalf("regex rejects fn %q but Validate accepted", fn)
		}
	})
}

// FuzzTriggerMatches: the wildcard/empty-list matcher must never panic and must
// honor the documented rules: disabled never fires; an empty pattern list is a
// wildcard; '*' matches anything; otherwise exact membership.
func FuzzTriggerMatches(f *testing.F) {
	f.Add(true, "orders", "created", "orders", "created")
	f.Add(false, "*", "*", "x", "y")
	f.Add(true, "", "", "anything", "anytype")
	f.Add(true, "\x00", "*", "\x00", "z")
	f.Fuzz(func(t *testing.T, enabled bool, agg, evt, candAgg, candEvt string) {
		tr := Trigger{Enabled: enabled, Aggregates: []string{agg}, EventTypes: []string{evt}}
		got := tr.matches(candAgg, candEvt) // must not panic
		if !enabled {
			if got {
				t.Fatalf("disabled trigger fired")
			}
			return
		}
		aggHit := agg == "*" || agg == candAgg
		evtHit := evt == "*" || evt == candEvt
		if got != (aggHit && evtHit) {
			t.Fatalf("matches(%q,%q) over [%q]/[%q] = %v, want %v", candAgg, candEvt, agg, evt, got, aggHit && evtHit)
		}
	})
}

func TestFunctriggersConstErrorParity(t *testing.T) {
	cases := []struct {
		err error
		msg string
	}{
		{ErrNotFound, "function trigger not found"},
		{ErrConflict, "function trigger with that name already exists"},
	}
	for _, c := range cases {
		if c.err.Error() != c.msg {
			t.Fatalf("Error() = %q, want %q", c.err.Error(), c.msg)
		}
		if !errors.Is(fmt.Errorf("ctx: %w", c.err), c.err) {
			t.Fatalf("errors.Is(wrap(%q), sentinel) = false", c.msg)
		}
	}
	if errors.Is(ErrNotFound, ErrConflict) {
		t.Fatal("ErrNotFound must not match ErrConflict")
	}
}
