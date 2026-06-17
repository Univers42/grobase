package shared

import (
	"log/slog"
	"os"
)

// NewLogger returns a JSON structured logger tagged with the service name.
func NewLogger(service string) *slog.Logger {
	level := slog.LevelInfo
	if os.Getenv("LOG_LEVEL") == "debug" {
		level = slog.LevelDebug
	}
	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	return slog.New(handler).With("service", service)
}

// WithTenant returns a child logger carrying tenant_id as a STRUCTURED FIELD
// (a Loki field via promtail, never a label). No-op passthrough when obs is off.
//
// B5 Pillar 1 (per-tenant observability): when TENANT_OBS_ENABLED is on, the
// per-request log line carries a tenant_id JSON field that promtail extracts
// into an EXPRESSION (a Loki field, queryable via `| json | tenant_id="X"`) —
// NOT a Loki label, so it creates zero new label streams at 10K+ tenants.
//
// When the flag is OFF (default) this is a literal identity function: it returns
// the SAME *slog.Logger, so every existing log line is byte-identical to the
// pre-B5 baseline (kernel rule #5). The flag is read in exactly one place so the
// whole control plane shares one switch.
func WithTenant(l *slog.Logger, tenantID string) *slog.Logger {
	if !tenantObsEnabled() || tenantID == "" {
		return l
	}
	return l.With("tenant_id", tenantID)
}

// tenantObsEnabled is the single source of truth for the Pillar-1 log-field
// flag. Default OFF (unset) so the live baseline is unchanged.
func tenantObsEnabled() bool {
	v := os.Getenv("TENANT_OBS_ENABLED")
	return v == "1" || v == "true"
}

// tenantObsCounterEnabled gates the OPTIONAL Pillar-3 bounded per-tenant request
// counter. It is AND-gated under the parent flag: the counter sub-flag does
// nothing unless TENANT_OBS_ENABLED is also on. Default OFF even when the parent
// is ON, because the counter path is the only place a mistake can cost Prometheus
// cardinality.
func tenantObsCounterEnabled() bool {
	if !tenantObsEnabled() {
		return false
	}
	v := os.Getenv("TENANT_OBS_COUNTER")
	return v == "1" || v == "true"
}
