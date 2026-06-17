package shared

import (
	"fmt"
	"os"
)

// vaultEncKeyEnv is the control plane's master credential: the AES-256-GCM
// master key (crypto.go) that seals every tenant DSN. If it is the publicly
// known compose placeholder, every credential is encrypted under a value an
// attacker can read from the repo — the exact fail-open SECURITY_MODE=max must
// refuse.
const vaultEncKeyEnv = "VAULT_ENC_KEY"

// minVaultEncKeyChars matches the encryptor's own guard (crypto.go minKeyChars):
// a master key shorter than this is not a real secret.
const minVaultEncKeyChars = 16

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

// requireVaultBackedCredentials enforces the G-Vault fail-closed contract.
//
//   - mode != "max" (default "baseline"): NO-OP. Returns nil immediately so the
//     boot path is byte-identical to the live baseline — the enforcement adds
//     zero work and zero behavior change when off.
//   - mode == "max": the master encryption key MUST be present, long enough to
//     be a real secret, NOT a publicly-known placeholder, and provably sourced
//     from Vault. Otherwise we refuse to boot, with no silent env fallback.
func requireVaultBackedCredentials(mode string) error {
	if mode != securityModeMax {
		return nil // OFF (default) — byte-parity short-circuit, before any work.
	}
	if err := validateEncKey(os.Getenv(vaultEncKeyEnv)); err != nil {
		return err
	}
	return requireVaultProvenance()
}

// validateEncKey rejects an absent/placeholder master key and one too short to
// be a real secret.
func validateEncKey(encKey string) error {
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
	return nil
}

// requireVaultProvenance requires a Vault address to be wired (or an explicit
// VAULT_CREDENTIAL_SOURCE=vault out-of-band assertion) so the credential is
// demonstrably sourced from Vault rather than an inline env literal.
func requireVaultProvenance() error {
	if os.Getenv("VAULT_ADDR") == "" && os.Getenv("VAULT_CREDENTIAL_SOURCE") != "vault" {
		return fmt.Errorf(
			"SECURITY_MODE=max requires Vault-backed credentials: neither VAULT_ADDR "+
				"nor VAULT_CREDENTIAL_SOURCE=vault is set, so %s cannot be proven to "+
				"originate from Vault (refusing to boot — no silent env fallback)",
			vaultEncKeyEnv)
	}
	return nil
}
