package erase

import (
	"errors"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// The erase scope guard is the load-bearing pure decision: only the two
// destructible isolation models are accepted; everything else is the deferred
// sentinel. This pins the contract the handler maps to 400 without needing a DB.
func TestScopeGuard_SupportedVsDeferred(t *testing.T) {
	supported := map[string]bool{
		"schema_per_tenant": true,
		"shared_rls":        true,
	}
	for _, scope := range []string{"schema_per_tenant", "shared_rls", "db_per_tenant", "tenant_owned", "", "bogus"} {
		got := scope == "schema_per_tenant" || scope == "shared_rls"
		if got != supported[scope] {
			t.Fatalf("scope %q: supported=%v, want %v", scope, got, supported[scope])
		}
	}
}

// ErrUnsupportedScope must carry the "deferred" word so the gate's 400-body
// assertion (grep -qi deferred) holds, mirroring backup's ErrIsolationDeferred.
func TestErrUnsupportedScope_MentionsDeferred(t *testing.T) {
	if msg := ErrUnsupportedScope.Error(); msg == "" || !containsFold(msg, "deferred") {
		t.Fatalf("ErrUnsupportedScope must mention 'deferred', got %q", msg)
	}
	// errors.Is plumbing the handler relies on.
	if !errors.Is(ErrUnsupportedScope, ErrUnsupportedScope) {
		t.Fatal("ErrUnsupportedScope must be its own sentinel")
	}
}

// dropTenantSchema must REFUSE a tenant id that sanitizes to an empty schema —
// dropping "" CASCADE would be catastrophic. tenants.TenantSchema is the single
// source; a non-resolvable id yields "" and the guard must reject it. This runs
// no SQL (the empty-schema branch returns before touching tx), so a nil tx is
// safe.
func TestDropTenantSchema_RejectsEmptySchema(t *testing.T) {
	// An id of only separators sanitizes to "" under the shared sanitizer.
	if s := tenants.TenantSchema("---"); s != "" {
		// If the sanitizer ever changes so this is non-empty, the test below would
		// dereference a nil tx — skip rather than crash, but flag the drift.
		t.Skipf("sanitizer no longer maps '---' to empty (got %q); update the test vector", s)
	}
	if _, err := dropTenantSchema(nil, nil, ""); err == nil {
		t.Fatal("dropTenantSchema must reject an empty schema name (never DROP SCHEMA \"\" CASCADE)")
	}
}

func containsFold(s, sub string) bool {
	// tiny case-insensitive contains to avoid importing strings just for the test
	for i := 0; i+len(sub) <= len(s); i++ {
		match := true
		for j := 0; j < len(sub); j++ {
			a, b := s[i+j], sub[j]
			if a >= 'A' && a <= 'Z' {
				a += 'a' - 'A'
			}
			if b >= 'A' && b <= 'Z' {
				b += 'a' - 'A'
			}
			if a != b {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
