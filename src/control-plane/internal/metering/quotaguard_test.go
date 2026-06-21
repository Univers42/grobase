/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   quotaguard_test.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:47:17 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:47:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package metering

import (
	"context"
	"testing"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
)

// loadGuard builds a guard with the real embedded manifest but no DB/Redis — just
// enough to exercise the pure over/under decision + period math.
func loadGuard(t *testing.T) *QuotaGuard {
	t.Helper()
	m, err := packages.Load()
	if err != nil {
		t.Fatalf("load manifest: %v", err)
	}
	return &QuotaGuard{manifest: m, metric: "query.count"}
}

// The load-bearing decision: a tenant on a capped tier whose summed usage EXCEEDS
// the tier cap is over quota; at-or-below is under. Uses the REAL packages.json
// caps so the test pins the actual advertised quota, not an invented number.
func TestIsOverQuota(t *testing.T) {
	g := loadGuard(t)
	// nano caps query.count at 100000/month (packages.json source of truth).
	nanoCap, ok := func() (uint64, bool) { _, p := g.manifest.For("nano"); return p.QueryCountCap() }()
	if !ok || nanoCap != 100000 {
		t.Fatalf("nano query.count cap: got %d (set=%v), want 100000", nanoCap, ok)
	}
	cases := []struct {
		name string
		plan string
		qty  int64
		over bool
	}{
		{"nano just over", "nano", int64(nanoCap) + 1, true},
		{"nano exactly at cap", "nano", int64(nanoCap), false},
		{"nano under", "nano", 10, false},
		{"max is unlimited (no quota block)", "max", 1_000_000_000, false},
		{"free alias resolves to nano cap → over", "free", int64(nanoCap) + 1, true},
		{"unknown plan degrades to default tier (essential), under its 2M cap", "bogus", 5, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// nil resolver → manifest.For path (byte-parity); slug is unused on that
			// path, so an empty slug exercises exactly the pre-builder decision.
			if got := g.isOverQuota(context.Background(), "", c.plan, c.qty); got != c.over {
				t.Fatalf("isOverQuota(%q, %d) = %v, want %v", c.plan, c.qty, got, c.over)
			}
		})
	}
}

// periodStartFor must return the inclusive start of the rolling window so the
// usage SQL sums only the current period. A typo'd period falls back to "month".
func TestPeriodStartFor(t *testing.T) {
	now := time.Date(2026, 6, 14, 13, 45, 30, 0, time.UTC)
	want := map[string]time.Time{
		"hour":    time.Date(2026, 6, 14, 13, 0, 0, 0, time.UTC),
		"day":     time.Date(2026, 6, 14, 0, 0, 0, 0, time.UTC),
		"month":   time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC),
		"garbage": time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC), // fallback = month
	}
	for period, exp := range want {
		if got := periodStartFor(period, now); !got.Equal(exp) {
			t.Fatalf("periodStartFor(%q) = %v, want %v", period, got, exp)
		}
	}
}
