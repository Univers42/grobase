/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   metrics_test.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:47:48 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:47:49 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package observability

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetricsObserveAndExposition(t *testing.T) {
	// Use a local sink (not the package global) to keep the test hermetic.
	m := &Metrics{start: time.Now()}
	m.SetService("unit-test")
	m.Observe("GET", 200, 5*time.Millisecond)
	m.Observe("GET", 204, 7*time.Millisecond)
	m.Observe("POST", 404, 1*time.Millisecond)

	rec := httptest.NewRecorder()
	m.WriteProm(rec)
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
	m := &Metrics{start: time.Now()}
	m.SetService("unit-test")
	// Two labels on one metric + one unlabeled metric; repeated bumps sum.
	m.IncCounter("baas_webhook_deliveries_total", "delivery outcomes", "outcome", "success")
	m.IncCounter("baas_webhook_deliveries_total", "delivery outcomes", "outcome", "success")
	m.IncCounter("baas_webhook_deliveries_total", "delivery outcomes", "outcome", "retry")
	m.IncCounter("baas_widgets_total", "widgets", "", "")

	body := func() string {
		rec := httptest.NewRecorder()
		m.WriteProm(rec)
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
