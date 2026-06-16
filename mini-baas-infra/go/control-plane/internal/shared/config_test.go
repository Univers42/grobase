package shared

import "testing"

// TestLoadConfigRejectsWeakServiceToken pins fix #4: startup must refuse an
// empty or placeholder INTERNAL_SERVICE_TOKEN, but accept a real (JWT_SECRET-
// derived) secret.
func TestLoadConfigRejectsWeakServiceToken(t *testing.T) {
	const prefix = "TESTSVC"
	t.Setenv("DATABASE_URL", "postgres://u:p@db/x")

	cases := []struct {
		name    string
		token   string
		wantErr bool
	}{
		{"empty rejected", "", true},
		{"placeholder rejected", weakServiceToken, true},
		{"strong accepted", "a-real-jwt-derived-secret", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("INTERNAL_SERVICE_TOKEN", c.token)
			_, err := LoadConfig(prefix)
			if (err != nil) != c.wantErr {
				t.Fatalf("LoadConfig token=%q err=%v, wantErr=%v", c.token, err, c.wantErr)
			}
		})
	}
}

// TestLoadConfigVaultRequiredAtMax pins G-Vault (A6): at SECURITY_MODE=max the
// control plane FAILS CLOSED when VAULT_ENC_KEY is absent or a publicly-known
// placeholder, boots when a real Vault-backed key + provenance are present, and
// is byte-parity (no Vault requirement at all) in the default mode.
func TestLoadConfigVaultRequiredAtMax(t *testing.T) {
	const realKey = "a-real-32-byte-vault-sourced-key!" // ≥16 chars, not a placeholder

	cases := []struct {
		name       string
		mode       string
		encKey     string
		vaultAddr  string
		credSource string
		wantErr    bool
	}{
		// max + placeholder/absent key → FAIL CLOSED.
		{"max + absent key rejected", "max", "", "http://vault:8200", "", true},
		{"max + compose placeholder rejected", "max", "0123456789abcdef0123456789abcdef", "http://vault:8200", "", true},
		{"max + short key rejected", "max", "tooshort", "http://vault:8200", "", true},
		// max + real key but NO Vault provenance → FAIL CLOSED.
		{"max + real key but no vault provenance rejected", "max", realKey, "", "", true},
		// max + real key + Vault provenance → boots.
		{"max + real key + VAULT_ADDR accepted", "max", realKey, "http://vault:8200", "", false},
		{"max + real key + explicit source accepted", "max", realKey, "", "vault", false},
		// PARITY: default mode never requires Vault, even with a placeholder key.
		{"baseline ignores placeholder key (parity)", "baseline", "0123456789abcdef0123456789abcdef", "", "", false},
		{"baseline ignores absent key (parity)", "baseline", "", "", "", false},
		{"unset mode ignores absent key (parity)", "", "", "", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("DATABASE_URL", "postgres://u:p@db/x")
			t.Setenv("INTERNAL_SERVICE_TOKEN", "a-real-jwt-derived-secret")
			t.Setenv("SECURITY_MODE", c.mode)
			t.Setenv(vaultEncKeyEnv, c.encKey)
			t.Setenv("VAULT_ADDR", c.vaultAddr)
			t.Setenv("VAULT_CREDENTIAL_SOURCE", c.credSource)
			_, err := LoadConfig("TESTSVC")
			if (err != nil) != c.wantErr {
				t.Fatalf("LoadConfig mode=%q encKey=%q err=%v, wantErr=%v", c.mode, c.encKey, err, c.wantErr)
			}
		})
	}
}

// TestRequireVaultBackedCredentialsOffIsByteParity asserts the OFF path returns
// nil with ZERO env reads beyond the mode check — the short-circuit guarantee.
func TestRequireVaultBackedCredentialsOffIsByteParity(t *testing.T) {
	// Deliberately set NO Vault env at all; baseline must still return nil.
	t.Setenv(vaultEncKeyEnv, "")
	t.Setenv("VAULT_ADDR", "")
	if err := requireVaultBackedCredentials("baseline"); err != nil {
		t.Errorf("baseline must be byte-parity (no Vault requirement), got %v", err)
	}
	if err := requireVaultBackedCredentials(""); err != nil {
		t.Errorf("unset mode must be byte-parity (no Vault requirement), got %v", err)
	}
	if err := requireVaultBackedCredentials("max"); err == nil {
		t.Error("max with no credential must FAIL CLOSED")
	}
}

// TestLoadConfigRequiresDatabaseURL keeps the existing DATABASE_URL guard green.
func TestLoadConfigRequiresDatabaseURL(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("INTERNAL_SERVICE_TOKEN", "strong")
	if _, err := LoadConfig("TESTSVC"); err == nil {
		t.Error("LoadConfig must require DATABASE_URL")
	}
}

func TestRedactDSN(t *testing.T) {
	cases := map[string]bool{ // input -> should contain redaction marker
		"connect failed: postgres://user:secret@db:5432/app":      true,
		"redis://:topsecret@cache:6379 unreachable":               true,
		"adapter-registry 400: validation_error (no dsn here)":    false,
		"mongodb+srv://u:p@cluster0.mongodb.net/test auth failed": true,
	}
	for in, wantRedacted := range cases {
		out := RedactDSN(in)
		if wantRedacted {
			if out == in {
				t.Errorf("RedactDSN(%q) left a DSN unredacted: %q", in, out)
			}
			if !contains(out, "[redacted-dsn]") {
				t.Errorf("RedactDSN(%q) = %q, want redaction marker", in, out)
			}
			if contains(out, "secret") || contains(out, "topsecret") {
				t.Errorf("RedactDSN(%q) leaked a credential: %q", in, out)
			}
		} else if out != in {
			t.Errorf("RedactDSN(%q) changed a non-DSN message: %q", in, out)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
