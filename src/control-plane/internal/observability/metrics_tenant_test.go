package observability

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// expose renders a fresh metrics sink's Prometheus exposition for assertions.
func expose(m *Metrics) string {
	rec := httptest.NewRecorder()
	m.WriteProm(rec)
	return rec.Body.String()
}

// TestTenantObsOffIsByteParity proves the OFF default: even when ObserveTenant
// is called, no tenant_id series appears and the exposition is byte-identical to
// a sink that never saw the per-tenant path. This is the kernel rule #5 parity
// invariant for the Go half of B5.
func TestTenantObsOffIsByteParity(t *testing.T) {
	t.Setenv("TENANT_OBS_ENABLED", "")
	t.Setenv("TENANT_OBS_COUNTER", "")

	baseline := &Metrics{start: time.Unix(0, 0)}
	baseline.SetService("unit-test")
	baseline.Observe("GET", 200, 5*time.Millisecond)

	withTenant := &Metrics{start: time.Unix(0, 0)}
	withTenant.SetService("unit-test")
	withTenant.Observe("GET", 200, 5*time.Millisecond)
	// These MUST be no-ops while the flags are off.
	withTenant.ObserveTenant(200, "tenant-a")
	withTenant.ObserveTenant(404, "tenant-b")

	if got := expose(withTenant); strings.Contains(got, "tenant_id=") {
		t.Fatalf("OFF path leaked a tenant_id label:\n%s", got)
	}
	if baseline := expose(baseline); expose(withTenant) != baseline {
		t.Fatalf("OFF exposition not byte-identical to baseline\n--- with ---\n%s\n--- base ---\n%s",
			expose(withTenant), baseline)
	}
}

// TestTenantObsOnEmitsBoundedSeries proves the ON path emits tenant_id series on
// baas_http_requests_total (and ONLY that counter), one per (status,tenant).
func TestTenantObsOnEmitsBoundedSeries(t *testing.T) {
	t.Setenv("TENANT_OBS_ENABLED", "1")
	t.Setenv("TENANT_OBS_COUNTER", "1")

	m := &Metrics{start: time.Unix(0, 0)}
	m.SetService("unit-test")
	m.Observe("GET", 200, time.Millisecond)
	m.ObserveTenant(200, "tenant-a")
	m.ObserveTenant(200, "tenant-a")
	m.ObserveTenant(404, "tenant-b")

	body := expose(m)
	for _, want := range []string{
		`baas_http_requests_total{service="unit-test",status="2xx",tenant_id="tenant-a"} 2`,
		`baas_http_requests_total{service="unit-test",status="4xx",tenant_id="tenant-b"} 1`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("exposition missing %q\n--- body ---\n%s", want, body)
		}
	}
	// tenant_id must appear on NO metric other than baas_http_requests_total.
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "tenant_id=") && !strings.HasPrefix(line, "baas_http_requests_total{") {
			t.Fatalf("tenant_id label leaked onto a non-request metric: %q", line)
		}
	}
}

// TestTenantObsCounterSubFlagGated proves the counter sub-flag is AND-gated under
// the parent: parent ON but counter OFF emits no tenant series.
func TestTenantObsCounterSubFlagGated(t *testing.T) {
	t.Setenv("TENANT_OBS_ENABLED", "1")
	t.Setenv("TENANT_OBS_COUNTER", "")

	m := &Metrics{start: time.Unix(0, 0)}
	m.SetService("unit-test")
	m.ObserveTenant(200, "tenant-a")

	if got := expose(m); strings.Contains(got, "tenant_id=") {
		t.Fatalf("parent-on/counter-off must NOT emit tenant series:\n%s", got)
	}
}

// TestTenantSeriesCapHolds floods more than the cap of distinct tenants and
// asserts the distinct tenant_id values in the exposition never exceed cap+1,
// with the overflow folded into the "_over_cap" sentinel.
func TestTenantSeriesCapHolds(t *testing.T) {
	t.Setenv("TENANT_OBS_ENABLED", "1")
	t.Setenv("TENANT_OBS_COUNTER", "1")

	m := &Metrics{start: time.Unix(0, 0)}
	m.SetService("unit-test")
	flood := tenantSeriesCap + 200
	for i := 0; i < flood; i++ {
		m.ObserveTenant(200, "tenant-"+strconvItoa(i))
	}

	body := expose(m)
	distinct := map[string]struct{}{}
	for _, line := range strings.Split(body, "\n") {
		if i := strings.Index(line, `tenant_id="`); i >= 0 {
			rest := line[i+len(`tenant_id="`):]
			if j := strings.Index(rest, `"`); j >= 0 {
				distinct[rest[:j]] = struct{}{}
			}
		}
	}
	if len(distinct) > tenantSeriesCap+1 {
		t.Fatalf("cap breached: %d distinct tenant_id series > %d (cap+1)", len(distinct), tenantSeriesCap+1)
	}
	if _, ok := distinct[overCapSentinel]; !ok {
		t.Fatalf("expected overflow sentinel %q present under a flood of %d tenants; distinct=%d",
			overCapSentinel, flood, len(distinct))
	}
}

// TestSanitizeTenantLabelMirrorsRust pins the escape sequence to the Rust data
// plane's escape_label so the two planes' /metrics label values agree byte-for-
// byte: backslash, double-quote, newline (in that order).
func TestSanitizeTenantLabelMirrorsRust(t *testing.T) {
	cases := map[string]string{
		`plain`:           `plain`,
		`a"b`:             `a\"b`,
		`a\b`:             `a\\b`,
		"a\nb":            `a\nb`,
		`evil"} other="x`: `evil\"} other=\"x`,
	}
	for in, want := range cases {
		if got := sanitizeTenantLabel(in); got != want {
			t.Fatalf("sanitizeTenantLabel(%q) = %q, want %q", in, got, want)
		}
	}
}

// strconvItoa is a tiny local int->string to avoid importing strconv in a test
// that only needs distinct keys (keeps the import set minimal).
func strconvItoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b [20]byte
	pos := len(b)
	for i > 0 {
		pos--
		b[pos] = byte('0' + i%10)
		i /= 10
	}
	return string(b[pos:])
}
