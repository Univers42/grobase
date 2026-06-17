package metering

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Biller is the minimal Stripe surface the B3 reporter needs: push ONE metered
// usage data point. The real impl posts to the Stripe Meter Events API; a fake
// satisfies it in unit tests so the reporter's metric→event mapping and
// idempotency are provable without a Stripe account or network.
type Biller interface {
	ReportMeterEvent(ctx context.Context, ev MeterEvent) error
}

// MeterEvent is one usage data point reported to a Stripe billing meter. Stripe
// SUMS the values of all events for a (customer, meter) within a billing period,
// so the reporter sends one event PER usage WINDOW (value = that window's qty),
// never a running cumulative total — summing per-window deltas reconstructs the
// period total exactly. Identifier is the window's B1 idempotency_key: Stripe
// ignores a repeated identifier, so a re-send is a no-op on Stripe's side too.
type MeterEvent struct {
	EventName  string // the Stripe meter's event_name (from the catalog)
	CustomerID string // Stripe customer → payload[stripe_customer_id]
	Value      int64  // the metered quantity for this window → payload[value]
	Identifier string // dedup key (the window idempotency_key) → identifier
	Timestamp  int64  // unix seconds of the window start (optional)
}

// stripeBiller posts MeterEvents to POST {base}/v1/billing/meter_events. base
// defaults to https://api.stripe.com; the gate points it at a mock. Auth is a
// Bearer STRIPE_API_KEY. Stripe's Meter Events API is form-encoded.
type stripeBiller struct {
	base   string
	apiKey string
	http   *http.Client
}

func newStripeBiller(base, apiKey string) *stripeBiller {
	return &stripeBiller{
		base:   strings.TrimRight(base, "/"),
		apiKey: apiKey,
		http:   &http.Client{Timeout: 10 * time.Second},
	}
}

// ReportMeterEvent form-encodes and POSTs one meter event. A non-2xx response is
// an error so the caller leaves the window un-marked (retried next tick); Stripe's
// identifier-dedup makes that retry safe even after a partial success.
func (b *stripeBiller) ReportMeterEvent(ctx context.Context, ev MeterEvent) error {
	form := url.Values{}
	form.Set("event_name", ev.EventName)
	form.Set("payload[stripe_customer_id]", ev.CustomerID)
	form.Set("payload[value]", strconv.FormatInt(ev.Value, 10))
	if ev.Identifier != "" {
		form.Set("identifier", ev.Identifier)
	}
	if ev.Timestamp > 0 {
		form.Set("timestamp", strconv.FormatInt(ev.Timestamp, 10))
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		b.base+"/v1/billing/meter_events", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+b.apiKey)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := b.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("stripe meter_events %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	return nil
}
