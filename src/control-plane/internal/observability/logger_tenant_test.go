package observability

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"testing"
)

// jsonLogger builds a slog JSON logger writing into buf, tagged like NewLogger.
func jsonLogger(buf *bytes.Buffer, service string) *slog.Logger {
	h := slog.NewJSONHandler(buf, &slog.HandlerOptions{Level: slog.LevelInfo})
	return slog.New(h).With("service", service)
}

// TestWithTenantOffIsIdentity proves the OFF default is a literal identity
// function: it returns the SAME *slog.Logger pointer, so existing log lines are
// byte-identical (kernel rule #5).
func TestWithTenantOffIsIdentity(t *testing.T) {
	t.Setenv("TENANT_OBS_ENABLED", "")

	var buf bytes.Buffer
	base := jsonLogger(&buf, "unit-test")
	if got := WithTenant(base, "tenant-a"); got != base {
		t.Fatalf("WithTenant must return the same logger when OFF")
	}
	base.Info("request")
	var m map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &m); err != nil {
		t.Fatalf("log line not JSON: %v", err)
	}
	if _, ok := m["tenant_id"]; ok {
		t.Fatalf("OFF log line must not carry tenant_id: %v", m)
	}
}

// TestWithTenantOnAttachesField proves the ON path attaches tenant_id as a
// structured JSON field (a Loki field, not a label).
func TestWithTenantOnAttachesField(t *testing.T) {
	t.Setenv("TENANT_OBS_ENABLED", "1")

	var buf bytes.Buffer
	base := jsonLogger(&buf, "unit-test")
	reqLog := WithTenant(base, "tenant-xyz")
	if reqLog == base {
		t.Fatalf("WithTenant must return a child logger when ON")
	}
	reqLog.Info("request")
	var m map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &m); err != nil {
		t.Fatalf("log line not JSON: %v", err)
	}
	if m["tenant_id"] != "tenant-xyz" {
		t.Fatalf("expected tenant_id field, got %v", m)
	}
}

// TestWithTenantEmptyIsIdentity proves an untenanted (admin/service-token)
// request is an identity no-op even when the flag is ON.
func TestWithTenantEmptyIsIdentity(t *testing.T) {
	t.Setenv("TENANT_OBS_ENABLED", "1")

	var buf bytes.Buffer
	base := jsonLogger(&buf, "unit-test")
	if got := WithTenant(base, ""); got != base {
		t.Fatalf("empty tenant_id must return the same logger")
	}
}
