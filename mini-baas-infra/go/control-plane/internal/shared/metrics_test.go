package shared

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetricsObserveAndExposition(t *testing.T) {
	// Use a local sink (not the package global) to keep the test hermetic.
	m := &metrics{start: time.Now()}
	m.setService("unit-test")
	m.observe("GET", 200, 5*time.Millisecond)
	m.observe("GET", 204, 7*time.Millisecond)
	m.observe("POST", 404, 1*time.Millisecond)

	rec := httptest.NewRecorder()
	m.writeProm(rec)
	body := rec.Body.String()

	want := []string{
		`baas_service_up{service="unit-test"} 1`,
		`baas_http_requests_total{service="unit-test",method="GET",status="2xx"} 2`,
		`baas_http_requests_total{service="unit-test",method="POST",status="4xx"} 1`,
		"baas_http_request_duration_ms_avg{service=\"unit-test\"}",
		"# TYPE baas_http_requests_total counter",
	}
	for _, w := range want {
		if !strings.Contains(body, w) {
			t.Fatalf("exposition missing %q\n--- body ---\n%s", w, body)
		}
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/plain") {
		t.Fatalf("unexpected content-type %q", ct)
	}
}

func TestCustomCountersExposition(t *testing.T) {
	m := &metrics{start: time.Now()}
	m.setService("unit-test")
	// Two labels on one metric + one unlabeled metric; repeated bumps sum.
	m.incCounter("baas_webhook_deliveries_total", "delivery outcomes", "outcome", "success")
	m.incCounter("baas_webhook_deliveries_total", "delivery outcomes", "outcome", "success")
	m.incCounter("baas_webhook_deliveries_total", "delivery outcomes", "outcome", "retry")
	m.incCounter("baas_widgets_total", "widgets", "", "")

	body := func() string {
		rec := httptest.NewRecorder()
		m.writeProm(rec)
		return rec.Body.String()
	}()

	for _, w := range []string{
		`baas_webhook_deliveries_total{service="unit-test",outcome="success"} 2`,
		`baas_webhook_deliveries_total{service="unit-test",outcome="retry"} 1`,
		`baas_widgets_total{service="unit-test"} 1`,
		"# TYPE baas_webhook_deliveries_total counter",
	} {
		if !strings.Contains(body, w) {
			t.Fatalf("exposition missing %q\n--- body ---\n%s", w, body)
		}
	}
	// HELP/TYPE must appear exactly once for the labeled metric despite 2 series.
	if n := strings.Count(body, "# TYPE baas_webhook_deliveries_total counter"); n != 1 {
		t.Fatalf("expected one TYPE line for the deliveries counter, got %d", n)
	}
}
