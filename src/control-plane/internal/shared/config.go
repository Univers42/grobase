// Package shared holds cross-service plumbing for the Go control plane:
// config loading, structured logging, the Postgres pool, and HTTP middleware.
package shared

import (
	"fmt"
	"os"
)

// weakServiceToken is the compose default-of-last-resort. A service must NOT
// boot with it (or an empty token): the internal service-token guard would then
// trust a publicly-known value, defeating control-plane auth. The real fallback
// is JWT_SECRET (a strong secret), which is accepted.
const weakServiceToken = "dev-service-token-change-me"

// securityModeMax is the strict production posture. At this mode the control
// plane REQUIRES Vault-backed credentials and FAILS CLOSED (refuses to boot)
// when the master credential is absent or a well-known placeholder — there is
// no silent fallback to an env/default value. Any other value (default
// "baseline") leaves the boot path byte-identical to today.
const securityModeMax = "max"

// vaultEncKeyEnv is the control plane's master credential: the AES-256-GCM
// master key (crypto.go) that seals every tenant DSN. If it is the publicly
// known compose placeholder, every credential is encrypted under a value an
// attacker can read from the repo — the exact fail-open SECURITY_MODE=max must
// refuse.
const vaultEncKeyEnv = "VAULT_ENC_KEY"

// placeholderEncKeys are the publicly-known dev defaults baked into
// docker-compose.yml (`VAULT_ENC_KEY: ${VAULT_ENC_KEY:-0123456789abcdef…}`).
// Booting at SECURITY_MODE=max with any of these means the credential was NOT
// supplied from Vault — it fell back to a repo-visible constant. Reject them.
var placeholderEncKeys = map[string]struct{}{
	"":                                 {}, // unset → no credential at all
	"0123456789abcdef0123456789abcdef": {}, // the compose default-of-last-resort
	"changeme":                         {},
	"change-me":                        {},
	"dev-vault-enc-key":                {},
}

// minVaultEncKeyChars matches the encryptor's own guard (crypto.go minKeyChars):
// a master key shorter than this is not a real secret.
const minVaultEncKeyChars = 16

// Config is the common runtime configuration for a control-plane service.
type Config struct {
	Host         string
	Port         string
	DatabaseURL  string
	ServiceToken string
	ProductMode  string
	// SecurityMode is the SECURITY_MODE posture (default "baseline"). Only
	// "max" activates the Vault-required fail-closed enforcement; every other
	// value keeps the boot path byte-identical to the live baseline.
	SecurityMode string
}

// LoadConfig reads <PREFIX>_HOST / <PREFIX>_PORT and shared DATABASE_URL.
// Example prefix: "ADAPTER_REGISTRY".
func LoadConfig(prefix string) (Config, error) {
	cfg := Config{
		Host:         envDefault(prefix+"_HOST", "0.0.0.0"),
		Port:         envDefault(prefix+"_PORT", "3021"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		ServiceToken: os.Getenv("INTERNAL_SERVICE_TOKEN"),
		ProductMode:  envDefault(prefix+"_PRODUCT_MODE", "shadow"),
		SecurityMode: envDefault("SECURITY_MODE", "baseline"),
	}
	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.ServiceToken == "" || cfg.ServiceToken == weakServiceToken {
		return Config{}, fmt.Errorf(
			"INTERNAL_SERVICE_TOKEN must be set to a strong value (refusing empty or the placeholder %q); "+
				"the live stack derives it from JWT_SECRET — set JWT_SECRET or ADAPTER_REGISTRY_SERVICE_TOKEN",
			weakServiceToken)
	}
	// G-Vault (A6) — at SECURITY_MODE=max the control plane REQUIRES a
	// Vault-backed master credential and FAILS CLOSED here (LoadConfig error →
	// main() os.Exit(1)) if it is absent or a repo-visible placeholder. Default
	// mode short-circuits → boot path byte-identical to today.
	if err := requireVaultBackedCredentials(cfg.SecurityMode); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// IsMaxSecurity reports whether the strict production posture is active.
func (c Config) IsMaxSecurity() bool {
	return c.SecurityMode == securityModeMax
}

// requireVaultBackedCredentials enforces the G-Vault fail-closed contract.
//
//   - mode != "max" (default "baseline"): NO-OP. Returns nil immediately so the
//     boot path is byte-identical to the live baseline — the enforcement adds
//     zero work and zero behavior change when off.
//   - mode == "max": the master encryption key (VAULT_ENC_KEY) MUST be present,
//     long enough to be a real secret, and NOT one of the publicly-known
//     compose placeholders. A placeholder/absent value means the credential was
//     never supplied from Vault — booting on it would silently seal every tenant
//     DSN under a repo-visible constant. We refuse to boot, with a clear error
//     and no silent env fallback.
func requireVaultBackedCredentials(mode string) error {
	if mode != securityModeMax {
		return nil // OFF (default) — byte-parity short-circuit, before any work.
	}
	encKey := os.Getenv(vaultEncKeyEnv)
	if _, isPlaceholder := placeholderEncKeys[encKey]; isPlaceholder {
		return fmt.Errorf(
			"SECURITY_MODE=max requires a Vault-backed %s: refusing to boot on an "+
				"absent or publicly-known placeholder value (no silent fallback). "+
				"Supply a real per-deployment secret from Vault (e.g. via "+
				"`make vault-fetch-shared` / VAULT_ADDR) before enabling max mode",
			vaultEncKeyEnv)
	}
	if len(encKey) < minVaultEncKeyChars {
		return fmt.Errorf(
			"SECURITY_MODE=max requires a Vault-backed %s of at least %d chars: "+
				"the supplied value is too short to be a real secret (refusing to "+
				"boot — no silent fallback to a weak credential)",
			vaultEncKeyEnv, minVaultEncKeyChars)
	}
	// Provenance: at max we additionally require a Vault address to be wired, so
	// the credential is demonstrably sourced from a Vault rather than an inline
	// env literal. VAULT_CREDENTIAL_SOURCE=vault is an explicit override for
	// deployments that inject the already-resolved secret out-of-band (still a
	// positive assertion of Vault provenance, never a silent default).
	if os.Getenv("VAULT_ADDR") == "" && os.Getenv("VAULT_CREDENTIAL_SOURCE") != "vault" {
		return fmt.Errorf(
			"SECURITY_MODE=max requires Vault-backed credentials: neither VAULT_ADDR "+
				"nor VAULT_CREDENTIAL_SOURCE=vault is set, so %s cannot be proven to "+
				"originate from Vault (refusing to boot — no silent env fallback)",
			vaultEncKeyEnv)
	}
	return nil
}

// ListenAddr returns host:port for http.Server.
func (c Config) ListenAddr() string {
	return c.Host + ":" + c.Port
}

func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
