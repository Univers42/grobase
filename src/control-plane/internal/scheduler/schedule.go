// Package scheduler implements scheduled (cron) function invocation (A2
// Functions DX). No external cron library is available in go.mod offline, so
// the schedule grammar is a deliberately small, zero-dep interval dialect with
// a couple of convenience aliases. Parsing + next-run math are pure functions
// (ParseSchedule / Schedule.Next / IsDue) so they are fully unit-testable
// without a database or clock.
package scheduler

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Schedule is a parsed schedule expression. Today only fixed intervals are
// supported; the type leaves room for richer cron fields later.
type Schedule struct {
	// Raw is the original expression string.
	Raw string
	// Interval is the fixed gap between runs.
	Interval time.Duration
}

// Minimum interval guards against busy-loops / runaway invocation.
const minInterval = 1 * time.Second

// ParseSchedule parses the supported schedule grammar:
//
//	"@every 30s" / "@every 5m" / "@every 1h"   explicit interval
//	"@hourly"                                    == @every 1h
//	"@daily" / "@midnight"                       == @every 24h
//	"@weekly"                                    == @every 168h
//	"30"                                         bare seconds (== 30s)
//	"30s" / "5m" / "2h" / "90m"                  bare Go duration
//
// It is intentionally strict: anything else is an error so a typo never
// silently becomes "every nanosecond".
func ParseSchedule(expr string) (Schedule, error) {
	raw := strings.TrimSpace(expr)
	if raw == "" {
		return Schedule{}, fmt.Errorf("empty schedule expression")
	}
	lower := strings.ToLower(raw)

	switch lower {
	case "@hourly":
		return Schedule{Raw: raw, Interval: time.Hour}, nil
	case "@daily", "@midnight":
		return Schedule{Raw: raw, Interval: 24 * time.Hour}, nil
	case "@weekly":
		return Schedule{Raw: raw, Interval: 7 * 24 * time.Hour}, nil
	}

	if strings.HasPrefix(lower, "@every ") {
		d, err := parseDuration(strings.TrimSpace(lower[len("@every "):]))
		if err != nil {
			return Schedule{}, fmt.Errorf("@every: %w", err)
		}
		return finalize(raw, d)
	}

	d, err := parseDuration(lower)
	if err != nil {
		return Schedule{}, fmt.Errorf("unrecognized schedule %q (use @every <dur>, @hourly, @daily, or a duration like 30s/5m/1h)", raw)
	}
	return finalize(raw, d)
}

func parseDuration(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty duration")
	}
	// Bare integer => seconds.
	if n, err := strconv.Atoi(s); err == nil {
		return time.Duration(n) * time.Second, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("invalid duration %q", s)
	}
	return d, nil
}

func finalize(raw string, d time.Duration) (Schedule, error) {
	if d < minInterval {
		return Schedule{}, fmt.Errorf("interval %v below minimum %v", d, minInterval)
	}
	return Schedule{Raw: raw, Interval: d}, nil
}

// Next returns the next run time strictly after `from`. For a fixed-interval
// schedule that is simply from+Interval, but if a run was missed (the service
// was down), it advances in whole intervals past `now` so we don't replay a
// backlog of fires — we fire once and resync to the cadence.
func (s Schedule) Next(from, now time.Time) time.Time {
	if s.Interval <= 0 {
		return from
	}
	next := from.Add(s.Interval)
	if next.After(now) {
		return next
	}
	// Catch up: skip whole missed intervals so the next run is in the future.
	missed := now.Sub(from) / s.Interval
	return from.Add((missed + 1) * s.Interval)
}

// IsDue reports whether a schedule with the given next_run is due at `now`.
func IsDue(nextRun, now time.Time) bool {
	return !nextRun.After(now)
}
