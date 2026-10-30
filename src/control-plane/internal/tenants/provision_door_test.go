package tenants

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"testing"
)

// The provision door (ADR 0023, devil P0 2026-10-30) is bounded because it sends ONE
// fixed statement on a tenant_control-signed migrate. If this test has to change to let
// a caller influence the statements, the P1 arm split is back on the table
// (.out-of-scope/provision-door-arm-split.md).
func TestProvisionDoorSendsOnlyTheFixedStatement(t *testing.T) {
	safe := regexp.MustCompile(`^tenant_[a-z0-9_]+$`)
	for _, slug := range []string{"t-acme", "a; DROP SCHEMA public", "Tab\tCo'--"} {
		var got []string
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var body struct {
				Statements []string `json:"statements"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Errorf("decode migrate body: %v", err)
			}
			got = body.Statements
			_, _ = w.Write([]byte(`{"status":"applied"}`))
		}))
		schema := tenantSchema(slug)
		err := NewDataPlane(srv.URL, "tok").ensureSchema(context.Background(), slug, schema,
			MountSpec{Engine: "postgresql", Name: "db", ConnectionString: "postgres://x"})
		srv.Close()
		if err != nil {
			t.Fatalf("ensureSchema(%q): %v", slug, err)
		}
		if !safe.MatchString(schema) {
			t.Fatalf("tenantSchema(%q) = %q, outside ^tenant_[a-z0-9_]+$", slug, schema)
		}
		if want := "CREATE SCHEMA IF NOT EXISTS " + schema; len(got) != 1 || got[0] != want {
			t.Fatalf("slug %q sent statements %q, want exactly [%q]", slug, got, want)
		}
	}
}
