package scheduler

import (
	"testing"
	"time"
)

func TestParseScheduleValid(t *testing.T) {
	cases := []struct {
		expr string
		want time.Duration
	}{
		{"@every 30s", 30 * time.Second},
		{"@every 5m", 5 * time.Minute},
		{"@every 1h", time.Hour},
		{"@hourly", time.Hour},
		{"@daily", 24 * time.Hour},
		{"@midnight", 24 * time.Hour},
		{"@weekly", 7 * 24 * time.Hour},
		{"30", 30 * time.Second}, // bare integer => seconds
		{"30s", 30 * time.Second},
		{"90m", 90 * time.Minute},
		{"2h", 2 * time.Hour},
		{"  @every   45s  ", 45 * time.Second}, // whitespace tolerant
		{"@EVERY 1h", time.Hour},               // case-insensitive
	}
	for _, tc := range cases {
		t.Run(tc.expr, func(t *testing.T) {
			s, err := ParseSchedule(tc.expr)
			if err != nil {
				t.Fatalf("ParseSchedule(%q) error: %v", tc.expr, err)
			}
			if s.Interval != tc.want {
				t.Fatalf("ParseSchedule(%q).Interval = %v, want %v", tc.expr, s.Interval, tc.want)
			}
		})
	}
}

func TestParseScheduleInvalid(t *testing.T) {
	bad := []string{
		"",
		"   ",
		"every 5m",      // missing @
		"@every",        // no duration
		"@every banana", // not a duration
		"@every 500ms",  // below 1s minimum
		"0",             // zero seconds -> below minimum
		"5x",            // bad unit
		"@yearly",       // unsupported alias
		"* * * * *",     // classic cron not supported
	}
	for _, expr := range bad {
		t.Run(expr, func(t *testing.T) {
			if _, err := ParseSchedule(expr); err == nil {
				t.Fatalf("ParseSchedule(%q) expected error, got nil", expr)
			}
		})
	}
}

func TestScheduleNextSimple(t *testing.T) {
	base := time.Date(2026, 6, 13, 12, 0, 0, 0, time.UTC)
	s := Schedule{Interval: time.Hour}
	// now is right at base; next is base+1h
	got := s.Next(base, base)
	want := base.Add(time.Hour)
	if !got.Equal(want) {
		t.Fatalf("Next = %v, want %v", got, want)
	}
}

func TestScheduleNextCatchUpSkipsBacklog(t *testing.T) {
	from := time.Date(2026, 6, 13, 12, 0, 0, 0, time.UTC)
	s := Schedule{Interval: time.Hour}
	// We were down for ~3.5h; from the scheduled "from", the next run must be
	// strictly in the future and aligned to the cadence — not a replay.
	now := from.Add(3*time.Hour + 30*time.Minute)
	got := s.Next(from, now)
	if !got.After(now) {
		t.Fatalf("Next %v must be after now %v", got, now)
	}
	// 4 intervals past `from` = 16:00 (first cadence slot strictly after now)
	want := from.Add(4 * time.Hour)
	if !got.Equal(want) {
		t.Fatalf("Next catch-up = %v, want %v", got, want)
	}
}

func TestIsDue(t *testing.T) {
	now := time.Date(2026, 6, 13, 12, 0, 0, 0, time.UTC)
	if !IsDue(now.Add(-time.Second), now) {
		t.Fatal("past next_run should be due")
	}
	if !IsDue(now, now) {
		t.Fatal("next_run == now should be due")
	}
	if IsDue(now.Add(time.Second), now) {
		t.Fatal("future next_run should NOT be due")
	}
}

func TestCreateRequestValidate(t *testing.T) {
	ok := CreateRequest{Name: "nightly", FunctionName: "report", ScheduleExpr: "@daily"}
	if err := ok.Validate(); err != nil {
		t.Fatalf("expected valid, got %v", err)
	}
	bad := []CreateRequest{
		{Name: "", FunctionName: "report", ScheduleExpr: "@daily"},
		{Name: "x", FunctionName: "1bad", ScheduleExpr: "@daily"},
		{Name: "x", FunctionName: "report", ScheduleExpr: "nope"},
		{Name: "x", FunctionName: "report", ScheduleExpr: "@daily", TimeoutMs: 99999},
	}
	for i, b := range bad {
		if err := b.Validate(); err == nil {
			t.Fatalf("case %d expected error, got nil", i)
		}
	}
}

func TestItoa(t *testing.T) {
	cases := map[int]string{0: "0", 5: "5", 200: "200", 404: "404", -7: "-7"}
	for in, want := range cases {
		if got := itoa(in); got != want {
			t.Fatalf("itoa(%d) = %q, want %q", in, got, want)
		}
	}
}
