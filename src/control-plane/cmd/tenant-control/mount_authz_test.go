package main

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func authzStatus(t *testing.T, flag string) int {
	t.Helper()
	t.Setenv("AUTHZ_ENABLED", flag)
	b := &bootCtx{log: slog.Default(), mux: http.NewServeMux()}
	b.mountAuthz()
	rec := httptest.NewRecorder()
	b.mux.ServeHTTP(rec, httptest.NewRequest("POST", "/v1/authz/check", nil))
	return rec.Code
}

// OFF is not "mounted and refusing": the route must not exist (404), so the
// OSS edition is byte-identical.
func TestAuthzFlagOffIsNotMounted(t *testing.T) {
	for _, off := range []string{"", "0", "false"} {
		if got := authzStatus(t, off); got != http.StatusNotFound {
			t.Errorf("AUTHZ_ENABLED=%q: %d, want 404", off, got)
		}
	}
}

func TestAuthzFlagOnMountsAndDemandsAKey(t *testing.T) {
	if got := authzStatus(t, "1"); got != http.StatusUnauthorized {
		t.Fatalf("AUTHZ_ENABLED=1 without a key: %d, want 401", got)
	}
}
