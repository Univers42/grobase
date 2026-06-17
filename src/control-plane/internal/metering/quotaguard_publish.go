package metering

import (
	"context"
	"fmt"
	"time"
)

const (
	// quotaOverSet is the Redis SET the data plane reads to decide enforcement.
	// One member per over-quota tenant_id. A tenant absent from the set is
	// under quota (or enforcement is off) → served normally.
	quotaOverSet = "quota:over"
	// quotaOverStaging is the scratch key the guard builds the next set in, then
	// atomically RENAMEs onto quotaOverSet so a reader never sees a partial set.
	quotaOverStaging = "quota:over:staging"
)

// publish replaces the over-quota set atomically: clear the staging key, add the
// new members, RENAME staging→live (so a reader never sees a partial set), then
// PEXPIRE the live set so a crashed guard cannot leave a stale set enforcing
// forever. An EMPTY over set means "no tenant is over quota" — we DELETE the live
// key so the data plane's SMEMBERS returns empty (fail-OPEN: no enforcement).
func (g *QuotaGuard) publish(ctx context.Context, over []string) error {
	pipe := g.rdb.TxPipeline()
	pipe.Del(ctx, quotaOverStaging)
	if len(over) == 0 {
		// No over-quota tenants → the live set must be empty/absent.
		pipe.Del(ctx, quotaOverSet)
		if _, err := pipe.Exec(ctx); err != nil {
			return fmt.Errorf("quota-guard: publish empty set: %w", err)
		}
		g.log.Debug("quota-guard published over-quota set", "count", 0)
		return nil
	}
	members := make([]any, len(over))
	for i, m := range over {
		members[i] = m
	}
	pipe.SAdd(ctx, quotaOverStaging, members...)
	// Stale-set TTL: 3× the interval so a couple of missed ticks don't expire a
	// still-valid set, but a crashed guard's set self-clears within ~45s default.
	pipe.PExpire(ctx, quotaOverStaging, 3*g.interval)
	pipe.Rename(ctx, quotaOverStaging, quotaOverSet)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("quota-guard: publish set: %w", err)
	}
	g.log.Debug("quota-guard published over-quota set", "count", len(over))
	return nil
}

// periodStartFor returns the inclusive start of the current period for `now`.
// "hour"/"day"/"month" supported; an unknown period falls back to "month" (the
// catalog default) so a typo can never silently widen the window to "all time".
func periodStartFor(period string, now time.Time) time.Time {
	now = now.UTC()
	switch period {
	case "hour":
		return time.Date(now.Year(), now.Month(), now.Day(), now.Hour(), 0, 0, 0, time.UTC)
	case "day":
		return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	default: // "month"
		return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	}
}
