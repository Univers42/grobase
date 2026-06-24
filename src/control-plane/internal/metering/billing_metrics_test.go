/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   billing_metrics_test.go                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:46 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:47 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package metering

import (
	"errors"
	"fmt"
	"testing"
)

// TestBillableMetricEnv_ExactMapping pins the EXACT metric → Stripe-meter
// ENV-var name the former map produced (now a switch). Each billable dimension
// must resolve to the precise BILLING_METER_* name a deployment configures, and
// an unknown metric must return "" (not billed). A renamed/dropped case here
// would silently stop billing a dimension.
func TestBillableMetricEnv_ExactMapping(t *testing.T) {
	want := map[string]string{
		"query.count":          "BILLING_METER_QUERY_COUNT",
		"query.rows":           "BILLING_METER_QUERY_ROWS",
		"write.rows":           "BILLING_METER_WRITE_ROWS",
		"storage.bytes":        "BILLING_METER_STORAGE_BYTES",
		"realtime.minutes":     "BILLING_METER_REALTIME_MINUTES",
		"function.invocations": "BILLING_METER_FUNCTION_INVOCATIONS",
	}
	for metric, env := range want {
		if got := billableMetricEnv(metric); got != env {
			t.Errorf("billableMetricEnv(%q) = %q, want %q", metric, got, env)
		}
	}
	for _, unknown := range []string{"", "query", "query.count ", "QUERY.COUNT", "ingress.bytes", "rows"} {
		if got := billableMetricEnv(unknown); got != "" {
			t.Errorf("billableMetricEnv(%q) = %q, want \"\" (unknown metric must not bill)", unknown, got)
		}
	}
}

// TestBillableMetrics_ClosedSet pins the frozen B1 metric vocabulary AND its
// coupling to billableMetricEnv: the set is exactly these six, in this order,
// and every one of them maps to a non-empty env name (no orphan metric).
func TestBillableMetrics_ClosedSet(t *testing.T) {
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
			t.Errorf("metric %q in billableMetrics has no env mapping (orphan)", got[i])
		}
	}
}

// TestMeteringErr_ConstParity proves the const error type still satisfies the
// errors.Is contract: wrapping errBadEntry with %w preserves identity, its
// message is the documented literal, and two references to the same const
// compare equal (direct == still holds, the property the consumer relied on).
func TestMeteringErr_ConstParity(t *testing.T) {
	const wantMsg = "metering: malformed usage entry"
	if errBadEntry.Error() != wantMsg {
		t.Errorf("errBadEntry.Error() = %q, want %q", errBadEntry.Error(), wantMsg)
	}
	wrapped := fmt.Errorf("parse row 7: %w", errBadEntry)
	if !errors.Is(wrapped, errBadEntry) {
		t.Error("errors.Is(wrapped, errBadEntry) = false, want true (%%w identity lost)")
	}
	// Direct equality (the const-string comparability property) still holds.
	var e error = errBadEntry
	if e != errBadEntry {
		t.Error("errBadEntry != errBadEntry via interface — const error not comparable")
	}
	// A different error must NOT match.
	if errors.Is(errors.New(wantMsg), errBadEntry) {
		t.Error("a distinct *errorString with the same text must not match errBadEntry")
	}
}
