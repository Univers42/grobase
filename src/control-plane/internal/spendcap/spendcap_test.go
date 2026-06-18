package spendcap

import (
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestParseCentsToMilli: the decimal cents → milli-cents (×1000) integer money
// conversion. A fractional cents-per-unit becomes an integer milli-cent so the
// hot money math never touches float; a malformed value is rejected.
func TestParseCentsToMilli(t *testing.T) {
	cases := []struct {
		in   string
		want int64
		ok   bool
	}{
		{"0.0001", 0, true}, // 0.0001¢ → 0.1 milli → rounds to 0 (priced too low to matter)
		{"0.001", 1, true},  // 0.001¢ → 1 milli-cent
		{"1", 1000, true},   // 1¢/unit → 1000 milli
		{"2.5", 2500, true}, // 2.5¢ → 2500 milli
		{"abc", 0, false},   // malformed → rejected
		{"-1", 0, false},    // negative → rejected
	}
	for _, c := range cases {
		got, ok := parseCentsToMilli(c.in)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("parseCentsToMilli(%q) = (%d,%v), want (%d,%v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

// TestSpendCentsFor: Σ(qty × milliRate)/1000 in whole cents. An unpriced metric
// contributes 0; the math is all-integer (no float drift).
func TestSpendCentsFor(t *testing.T) {
	rt := rateTable{milliPerUnit: map[string]int64{
		"query.count": 1,    // 1 milli-cent / query
		"write.rows":  1000, // 1 cent / write row
	}}
	usage := map[string]int64{
		"query.count":   2000, // 2000 milli = 2 cents
		"write.rows":    3,    // 3000 milli = 3 cents
		"storage.bytes": 999,  // unpriced → 0
	}
	if got := rt.spendCentsFor(usage); got != 5 {
		t.Fatalf("spendCentsFor = %d cents, want 5", got)
	}
}

// fakeDB satisfies spendDB. AdminQuery is unused on the alert path (returns nil
// pgx.Rows); AdminExec counts the once-per-period alert mark.
type fakeDB struct{ marks int }

func (f *fakeDB) AdminQuery(context.Context, string, ...any) (pgx.Rows, error) { return nil, nil }
func (f *fakeDB) AdminExec(context.Context, string, ...any) error              { f.marks++; return nil }

// captureAlerter records each fired alert + the last pct.
type captureAlerter struct {
	fires int
	pct   int
}

func (c *captureAlerter) BudgetAlert(_ context.Context, _ string, _, _ int64, pct int) {
	c.fires++
	c.pct = pct
}

// TestMaybeAlertFiresOncePerPeriod is the load-bearing reject: the 80% alert fires
// EXACTLY ONCE — an under-80% spend does not fire; once fired this period it never
// re-fires even at higher spend.
func TestMaybeAlertFiresOncePerPeriod(t *testing.T) {
	db := &fakeDB{}
	al := &captureAlerter{}
	g := &Guard{
		log:      slog.New(slog.NewTextHandler(discard{}, nil)),
		db:       db,
		alerter:  al,
		alertPct: 80,
	}
	now := time.Date(2026, 6, 14, 12, 0, 0, 0, time.UTC)
	ts := &tenantSpend{tenantID: "t", period: "month", budgetCents: 1000}

	g.maybeAlert(context.Background(), ts, 700, now) // 70% < 80% → no alert
	if al.fires != 0 {
		t.Fatalf("under-threshold should not alert, fires=%d", al.fires)
	}

	g.maybeAlert(context.Background(), ts, 850, now) // 85% ≥ 80% → fire once + mark
	if al.fires != 1 || al.pct != 85 {
		t.Fatalf("expected one fire at 85%%, got fires=%d pct=%d", al.fires, al.pct)
	}
	if db.marks != 1 {
		t.Fatalf("expected the alert-fired mark written once, got %d", db.marks)
	}

	g.maybeAlert(context.Background(), ts, 999, now) // already fired → no re-fire
	if al.fires != 1 {
		t.Fatalf("alert must fire once per period, fires=%d", al.fires)
	}
}

// TestZeroBudgetNeverAlerts: a 0 (unlimited) budget never alerts and is never over
// — the safe default for a tenant with no real cap.
func TestZeroBudgetNeverAlerts(t *testing.T) {
	db := &fakeDB{}
	al := &captureAlerter{}
	g := &Guard{log: slog.New(slog.NewTextHandler(discard{}, nil)), db: db, alerter: al, alertPct: 80}
	ts := &tenantSpend{tenantID: "t", period: "month", budgetCents: 0}
	g.maybeAlert(context.Background(), ts, 1_000_000, time.Now())
	if al.fires != 0 || db.marks != 0 {
		t.Fatalf("zero budget must not alert/mark, fires=%d marks=%d", al.fires, db.marks)
	}
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }
