package scheduler

import "time"

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
	missed := now.Sub(from) / s.Interval
	return from.Add((missed + 1) * s.Interval)
}

// IsDue reports whether a schedule with the given next_run is due at `now`.
func IsDue(nextRun, now time.Time) bool {
	return !nextRun.After(now)
}
