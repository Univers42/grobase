package config

import (
	"fmt"
	"os"
	"strings"
)

// serviceTokenKey is the variable every control-plane binary reads its service
// token from (compose maps ADAPTER_REGISTRY_SERVICE_TOKEN onto it).
const serviceTokenKey = "INTERNAL_SERVICE_TOKEN"

// serviceTokenProblem is how a refused token is reported: the key and the repo-
// visible placeholder, never a configured value.
const serviceTokenProblem = serviceTokenKey + " (empty, or the placeholder \"" + weakServiceToken +
	"\"; compose passes ADAPTER_REGISTRY_SERVICE_TOKEN — set it in .env.secrets, make env generates one)"

// secretGroup is one requirement satisfied by any one of its env keys; the
// first key is canonical. {"GOTRUE_JWT_SECRET", "JWT_SECRET"} is met by either.
type secretGroup []string

// name returns the keys joined for an error message — key names only.
func (g secretGroup) name() string {
	return strings.Join(g, " or ")
}

// present reports whether at least one key of the group is set and non-empty.
func (g secretGroup) present() bool {
	for _, key := range g {
		if os.Getenv(key) != "" {
			return true
		}
	}
	return false
}

// requiredSecrets returns the secrets a control-plane binary cannot run
// correctly without, beyond the DATABASE_URL and service token every binary
// needs. Each entry is a secret the binary reads unconditionally at boot:
//   - ADAPTER_REGISTRY: VAULT_ENC_KEY seals every tenant DSN (cmd/adapter-registry/service.go).
//   - TENANT_CONTROL: GOTRUE_JWT_SECRET or JWT_SECRET verifies user JWTs and mints sessions
//     (cmd/tenant-control/boot.go); without it self-serve bootstrap silently disappears.
//
// ORCHESTRATOR, FUNCTION_SCHEDULER and WEBHOOK_DISPATCHER add none: the
// webhook-dispatcher's VAULT_ENC_KEY is optional by design (it only mounts the
// function-secrets surface, cmd/webhook-dispatcher/setup.go).
//
// Ponytail: keyed by the LoadConfig prefix, so a new binary or a renamed prefix
// gets only the common set (under-reports) until it is added here;
// TestRequiredSecretsPerPrefix pins the five. Presence only: strength and
// placeholders stay SECURITY_MODE=max's job, and flag-gated secrets (SSO_SECRET_KEY,
// STRIPE_API_KEY, ...) are enforced at their own mount when the flag is on.
func requiredSecrets(prefix string) []secretGroup {
	switch prefix {
	case "ADAPTER_REGISTRY":
		return []secretGroup{{"VAULT_ENC_KEY"}}
	case "TENANT_CONTROL":
		return []secretGroup{{"GOTRUE_JWT_SECRET", "JWT_SECRET"}}
	}
	return nil
}

// missingKeys collects every unmet requirement instead of stopping at the first:
// DATABASE_URL and the service token in every environment, plus the prefix's
// secrets in a strict one. Entries are key names only, never values.
func (c Config) missingKeys(prefix string) []string {
	var missing []string
	if c.DatabaseURL == "" {
		missing = append(missing, "DATABASE_URL")
	}
	if c.ServiceToken == "" || c.ServiceToken == weakServiceToken {
		missing = append(missing, serviceTokenProblem)
	}
	if !c.Environment.Strict() {
		return missing
	}
	for _, group := range requiredSecrets(prefix) {
		if !group.present() {
			missing = append(missing, group.name())
		}
	}
	return missing
}

// requireConfigured returns nil when nothing is missing, otherwise one
// ErrMissingConfig-wrapping error that names every missing key.
func (c Config) requireConfigured(prefix string) error {
	missing := c.missingKeys(prefix)
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf("%w: %s (%s=%s)", ErrMissingConfig, strings.Join(missing, ", "), environmentKey, c.Environment)
}
