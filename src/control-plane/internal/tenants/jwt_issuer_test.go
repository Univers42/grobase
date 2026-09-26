package tenants

import "testing"

// TestRequireIssuer is M-5: an empty issuer is refused unless JWT_ALLOW_NO_ISSUER opts out.
func TestRequireIssuer(t *testing.T) {
	t.Setenv("JWT_ALLOW_NO_ISSUER", "")
	if err := RequireIssuer(""); err == nil {
		t.Fatal("empty issuer must be refused by default")
	}
	if err := RequireIssuer(" "); err == nil {
		t.Fatal("blank issuer must be refused by default")
	}
	if err := RequireIssuer("https://api.example/auth/v1"); err != nil {
		t.Fatalf("a configured issuer must pass: %v", err)
	}
	t.Setenv("JWT_ALLOW_NO_ISSUER", "1")
	if err := RequireIssuer(""); err != nil {
		t.Fatalf("opt-out set: an empty issuer must pass: %v", err)
	}
}
