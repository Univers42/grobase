package scheduler

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
	// Hold a valid schedule + name + timeout constant; vary one field at a time.
	base := CreateRequest{Name: "ok", FunctionName: "fn", ScheduleExpr: "@daily"}
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
		{"fn leading digit rejected", func(c CreateRequest) CreateRequest { c.FunctionName = "1bad"; return c }, false},
		{"fn dash ok", func(c CreateRequest) CreateRequest { c.FunctionName = "a-b"; return c }, true},
		{"fn 64 chars ok", func(c CreateRequest) CreateRequest { c.FunctionName = "a" + strings.Repeat("b", 63); return c }, true},
		{"fn 65 chars rejected", func(c CreateRequest) CreateRequest { c.FunctionName = "a" + strings.Repeat("b", 64); return c }, false},
		{"bad schedule rejected", func(c CreateRequest) CreateRequest { c.ScheduleExpr = "nope"; return c }, false},
		{"timeout 0 ok", func(c CreateRequest) CreateRequest { c.TimeoutMs = 0; return c }, true},
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

// FuzzCreateRequestValidate_FunctionName: with name+schedule+timeout fixed-valid,
// the only gate left is the function_name regex — parity with recompiling it.
func FuzzCreateRequestValidate_FunctionName(f *testing.F) {
	for _, s := range []string{"fn", "a-b", "a_b", "", "1bad", "has space",
		"A", "z9", "a\x00", "é", strings.Repeat("a", 64), strings.Repeat("a", 65), "a.b"} {
		f.Add(s)
	}
	re := regexp.MustCompile(funcNamePatternMirror)
	f.Fuzz(func(t *testing.T, fn string) {
		err := CreateRequest{Name: "ok", FunctionName: fn, ScheduleExpr: "@daily"}.Validate()
		want := re.MatchString(fn)
		if want && err != nil {
			t.Fatalf("regex accepts fn %q but Validate rejected: %v", fn, err)
		}
		if !want && err == nil {
			t.Fatalf("regex rejects fn %q but Validate accepted", fn)
		}
	})
}

// FuzzParseSchedule: the parser must never panic for ANY input; and any accepted
// schedule has an interval >= the documented minimum (1s).
func FuzzParseSchedule(f *testing.F) {
	for _, s := range []string{
		"@every 30s", "@hourly", "@daily", "@weekly", "@midnight", "30", "5m", "2h",
		"", "   ", "@every", "@every banana", "@every 500ms", "0", "@yearly", "* * * * *",
		"\x00", "@every \n", "999999999999999999999999h", "-5m", "@EVERY 1H",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, expr string) {
		s, err := ParseSchedule(expr) // must not panic
		if err != nil {
			return
		}
		if s.Interval < minInterval {
			t.Fatalf("ParseSchedule(%q) accepted interval %v below minimum %v", expr, s.Interval, minInterval)
		}
	})
}

func TestSchedulerConstErrorParity(t *testing.T) {
	cases := []struct {
		err error
		msg string
	}{
		{ErrNotFound, "function schedule not found"},
		{ErrConflict, "function schedule with that name already exists"},
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
