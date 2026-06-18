package functriggers

import (
	"testing"
	"time"
)

func TestTriggerMatches(t *testing.T) {
	cases := []struct {
		name      string
		trigger   Trigger
		aggregate string
		eventType string
		want      bool
	}{
		{
			name:      "wildcard matches everything",
			trigger:   Trigger{Enabled: true, Aggregates: []string{"*"}, EventTypes: []string{"*"}},
			aggregate: "orders", eventType: "created", want: true,
		},
		{
			name:      "exact aggregate + type match",
			trigger:   Trigger{Enabled: true, Aggregates: []string{"orders"}, EventTypes: []string{"created"}},
			aggregate: "orders", eventType: "created", want: true,
		},
		{
			name:      "aggregate mismatch",
			trigger:   Trigger{Enabled: true, Aggregates: []string{"orders"}, EventTypes: []string{"*"}},
			aggregate: "users", eventType: "created", want: false,
		},
		{
			name:      "event type mismatch",
			trigger:   Trigger{Enabled: true, Aggregates: []string{"*"}, EventTypes: []string{"created"}},
			aggregate: "orders", eventType: "deleted", want: false,
		},
		{
			name:      "disabled never fires",
			trigger:   Trigger{Enabled: false, Aggregates: []string{"*"}, EventTypes: []string{"*"}},
			aggregate: "orders", eventType: "created", want: false,
		},
		{
			name:      "empty pattern list matches all",
			trigger:   Trigger{Enabled: true, Aggregates: nil, EventTypes: nil},
			aggregate: "orders", eventType: "created", want: true,
		},
		{
			name:      "one of multiple event types",
			trigger:   Trigger{Enabled: true, Aggregates: []string{"orders"}, EventTypes: []string{"created", "updated"}},
			aggregate: "orders", eventType: "updated", want: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.trigger.matches(tc.aggregate, tc.eventType); got != tc.want {
				t.Fatalf("matches(%q,%q) = %v, want %v", tc.aggregate, tc.eventType, got, tc.want)
			}
		})
	}
}

func TestCreateRequestValidate(t *testing.T) {
	valid := CreateRequest{Name: "on-order", FunctionName: "notify"}
	if err := valid.Validate(); err != nil {
		t.Fatalf("expected valid request, got %v", err)
	}

	bad := []CreateRequest{
		{Name: "", FunctionName: "notify"},                    // empty name
		{Name: "x", FunctionName: "1bad"},                     // bad function name (leading digit)
		{Name: "x", FunctionName: "notify", MaxAttempts: 99},  // max_attempts out of range
		{Name: "x", FunctionName: "notify", TimeoutMs: 99999}, // timeout out of range
	}
	for i, b := range bad {
		if err := b.Validate(); err == nil {
			t.Fatalf("case %d: expected validation error, got nil", i)
		}
	}
}

func TestInvokeURL(t *testing.T) {
	d := &Dispatcher{runtimeURL: "http://functions-runtime:3060"}
	got := d.invokeURL("notify")
	want := "http://functions-runtime:3060/v1/functions/notify/invoke"
	if got != want {
		t.Fatalf("invokeURL = %q, want %q", got, want)
	}
}

func TestBackoffMonotonicAndCapped(t *testing.T) {
	prev := time.Duration(0)
	for attempt := 1; attempt <= 12; attempt++ {
		d := backoff(attempt)
		if d <= 0 {
			t.Fatalf("attempt %d: backoff must be positive, got %v", attempt, d)
		}
		if d > 5*time.Minute {
			t.Fatalf("attempt %d: backoff %v exceeds 5m cap", attempt, d)
		}
		// monotonic non-decreasing up to the cap
		if attempt > 1 && d < prev && prev < 5*time.Minute {
			t.Fatalf("attempt %d: backoff decreased %v -> %v before cap", attempt, prev, d)
		}
		prev = d
	}
}

func TestStringFromPayload(t *testing.T) {
	p := map[string]any{"tenant_id": "tenant-1", "n": 5}
	if got := stringFromPayload(p, "tenant_id"); got != "tenant-1" {
		t.Fatalf("got %q, want tenant-1", got)
	}
	if got := stringFromPayload(p, "missing"); got != "" {
		t.Fatalf("missing key should be empty, got %q", got)
	}
	if got := stringFromPayload(p, "n"); got != "" {
		t.Fatalf("non-string value should be empty, got %q", got)
	}
	if got := stringFromPayload(nil, "x"); got != "" {
		t.Fatalf("nil payload should be empty, got %q", got)
	}
}
