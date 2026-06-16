package metering

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// fakeBiller records the meter events the reporter pushes (or fails them all).
type fakeBiller struct {
	events []MeterEvent
	fail   bool
}

func (f *fakeBiller) ReportMeterEvent(_ context.Context, ev MeterEvent) error {
	if f.fail {
		return errors.New("stripe down")
	}
	f.events = append(f.events, ev)
	return nil
}

// fakeBillingDB records the ledger marks; AdminQuery is unused by flush().
// failFirstExec makes the first AdminExec fail (to test mark-failure handling).
type fakeBillingDB struct {
	marks         [][]any
	execCalls     int
	failFirstExec bool
}

func (f *fakeBillingDB) AdminQuery(_ context.Context, _ string, _ ...any) (pgx.Rows, error) {
	return nil, errors.New("AdminQuery not exercised in flush tests")
}
func (f *fakeBillingDB) AdminExec(_ context.Context, _ string, args ...any) error {
	f.execCalls++
	if f.failFirstExec && f.execCalls == 1 {
		return errors.New("ledger write failed")
	}
	f.marks = append(f.marks, args)
	return nil
}

func testReporter(cat billingCatalog, b Biller, db billingRW) *BillingReporter {
	return &BillingReporter{
		log:           slog.New(slog.NewTextHandler(io.Discard, nil)),
		db:            db,
		biller:        b,
		catalog:       cat,
		enabled:       true,
		sendTimestamp: true, // exercise the window-timestamp path (default is receipt-time)
	}
}

func TestBillingCatalogFromEnv(t *testing.T) {
	t.Setenv("BILLING_METER_QUERY_COUNT", "grobase_query_count")
	cat := loadBillingCatalog()

	if name, ok := cat.eventName("query.count"); !ok || name != "grobase_query_count" {
		t.Fatalf("query.count should map to grobase_query_count, got (%q,%v)", name, ok)
	}
	if _, ok := cat.eventName("write.rows"); ok {
		t.Fatalf("write.rows must NOT be billable when its env is unset")
	}
	if cat.empty() {
		t.Fatalf("catalog must not be empty when one meter is configured")
	}
	ms := cat.metrics()
	if len(ms) != 1 || ms[0] != "query.count" {
		t.Fatalf("metrics() should be exactly [query.count], got %v", ms)
	}
}

func TestBillingFlushMapsMarksAndSkipsUnbilled(t *testing.T) {
	cat := billingCatalog{meters: map[string]string{"query.count": "grobase_query_count"}}
	b := &fakeBiller{}
	db := &fakeBillingDB{}
	r := testReporter(cat, b, db)

	rows := []usageRow{
		{idem: "k1", tenant: "t1", metric: "query.count", customer: "cus_1", qty: 10, windowUnix: 100},
		// query.rows is NOT in the catalog → must be skipped (no event, no mark).
		{idem: "k2", tenant: "t1", metric: "query.rows", customer: "cus_1", qty: 99, windowUnix: 100},
	}
	if err := r.flush(context.Background(), rows); err != nil {
		t.Fatalf("flush: %v", err)
	}

	if len(b.events) != 1 {
		t.Fatalf("expected exactly 1 meter event (the billable one), got %d", len(b.events))
	}
	ev := b.events[0]
	if ev.EventName != "grobase_query_count" || ev.CustomerID != "cus_1" ||
		ev.Value != 10 || ev.Identifier != "k1" || ev.Timestamp != 100 {
		t.Fatalf("meter event mismapped: %+v", ev)
	}
	if len(db.marks) != 1 {
		t.Fatalf("expected exactly 1 ledger mark, got %d", len(db.marks))
	}
	// markReportedSQL args: idem, tenant, metric, qty
	if db.marks[0][0] != "k1" || db.marks[0][1] != "t1" || db.marks[0][2] != "query.count" || db.marks[0][3].(int64) != 10 {
		t.Fatalf("ledger mark args wrong: %v", db.marks[0])
	}
}

func TestBillingFlushDoesNotMarkOnStripeFailure(t *testing.T) {
	cat := billingCatalog{meters: map[string]string{"query.count": "grobase_query_count"}}
	b := &fakeBiller{fail: true}
	db := &fakeBillingDB{}
	r := testReporter(cat, b, db)

	rows := []usageRow{{idem: "k1", tenant: "t1", metric: "query.count", customer: "cus_1", qty: 10, windowUnix: 100}}
	if err := r.flush(context.Background(), rows); err != nil {
		t.Fatalf("flush must not return a hard error on a per-row Stripe failure: %v", err)
	}
	if len(b.events) != 0 {
		t.Fatalf("failed biller must record no events")
	}
	if len(db.marks) != 0 {
		t.Fatalf("a window whose POST failed must NOT be marked reported (so it retries), got %d marks", len(db.marks))
	}
}

func TestBillingFlushContinuesPastMarkFailure(t *testing.T) {
	cat := billingCatalog{meters: map[string]string{"query.count": "grobase_query_count"}}
	b := &fakeBiller{}
	db := &fakeBillingDB{failFirstExec: true} // the first ledger mark fails
	r := testReporter(cat, b, db)

	rows := []usageRow{
		{idem: "k1", tenant: "t1", metric: "query.count", customer: "cus_1", qty: 10, windowUnix: 100},
		{idem: "k2", tenant: "t1", metric: "query.count", customer: "cus_1", qty: 20, windowUnix: 200},
	}
	err := r.flush(context.Background(), rows)
	if err == nil {
		t.Fatalf("flush must surface an aggregated error when a ledger mark fails")
	}
	// BOTH windows must still have been POSTed (a mark failure must not abandon the batch).
	if len(b.events) != 2 {
		t.Fatalf("both windows must be POSTed despite the first mark failing, got %d", len(b.events))
	}
	// Only the second window got a successful ledger mark (the first failed → un-marked → retried later).
	if len(db.marks) != 1 || db.marks[0][0] != "k2" {
		t.Fatalf("expected exactly the second window (k2) marked, got %v", db.marks)
	}
}

func TestBillingFloorCoversPreviousPeriod(t *testing.T) {
	r := &BillingReporter{period: "month"}
	got := r.billingFloor(time.Date(2026, 6, 14, 12, 0, 0, 0, time.UTC))
	want := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC) // start of the PREVIOUS month
	if !got.Equal(want) {
		t.Fatalf("billingFloor should be the previous-period start %v, got %v", want, got)
	}
}

func TestBillingReporterDisabledRunIsNoop(t *testing.T) {
	b := &fakeBiller{}
	r := &BillingReporter{
		log:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		db:      &fakeBillingDB{},
		biller:  b,
		enabled: false, // BILLING_ENABLED off
	}
	// Disabled Run must return immediately (no ticker, no work) and never bill.
	r.Run(context.Background())
	if len(b.events) != 0 {
		t.Fatalf("disabled reporter must make zero Stripe calls, got %d", len(b.events))
	}
}
