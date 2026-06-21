/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rate_metrics_test.go                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:56:04 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:56:06 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package spendcap

import "testing"

// TestBillableMetricEnv_ExactMapping pins the EXACT priceable-dimension →
// SPEND_RATE_* ENV-var name the former map produced (now a switch). A
// renamed/dropped case would silently price a dimension at zero.
func TestBillableMetricEnv_ExactMapping(t *testing.T) {
	want := map[string]string{
		"query.count":          "SPEND_RATE_QUERY_COUNT",
		"query.rows":           "SPEND_RATE_QUERY_ROWS",
		"write.rows":           "SPEND_RATE_WRITE_ROWS",
		"storage.bytes":        "SPEND_RATE_STORAGE_BYTES",
		"realtime.minutes":     "SPEND_RATE_REALTIME_MINUTES",
		"function.invocations": "SPEND_RATE_FUNCTION_INVOCATIONS",
	}
	for metric, env := range want {
		if got := billableMetricEnv(metric); got != env {
			t.Errorf("billableMetricEnv(%q) = %q, want %q", metric, got, env)
		}
	}
	for _, unknown := range []string{"", "spend", "query.count ", "QUERY.COUNT", "ingress.bytes"} {
		if got := billableMetricEnv(unknown); got != "" {
			t.Errorf("billableMetricEnv(%q) = %q, want \"\" (unknown must not price)", unknown, got)
		}
	}
}

// TestBillableMetrics_MirrorsMeteringVocabulary pins the frozen set and order.
// spendcap MUST share B1's exact metric vocabulary (same six, same order) — a
// divergence would price a dimension metering never meters or vice versa.
func TestBillableMetrics_MirrorsMeteringVocabulary(t *testing.T) {
	want := []string{
		"query.count", "query.rows", "write.rows",
		"storage.bytes", "realtime.minutes", "function.invocations",
	}
	got := billableMetrics()
	if len(got) != len(want) {
		t.Fatalf("billableMetrics() len = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("billableMetrics()[%d] = %q, want %q", i, got[i], want[i])
		}
		if billableMetricEnv(got[i]) == "" {
			t.Errorf("metric %q has no env mapping (orphan)", got[i])
		}
	}
}
