package branching

import (
	"errors"
	"fmt"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// ErrInvalidBranchName is returned when a caller-supplied branch name does not
// sanitize to a non-empty safe identifier. The handler maps it to 400. This is
// the LOAD-BEARING wall against SQL-identifier injection: the branch name flows
// into `CREATE SCHEMA <branch_schema>` (an identifier, never bindable), so it MUST
// be validated to a safe [a-z0-9_] fragment before it touches DDL.
var ErrInvalidBranchName = errors.New("invalid branch name (must be a non-empty [a-z0-9_] identifier)")

// sanitizeBranchName validates+normalizes a caller-supplied branch name to a safe
// SQL identifier fragment, mirroring tenants.tenantSchema's discipline (lowercase,
// keep [a-z0-9_], everything else is NOT silently rewritten — a name with an
// out-of-class char is REJECTED so a caller cannot smuggle `x; DROP SCHEMA …`
// past us). We reject (not rewrite) because a branch name is caller-facing and
// silently mangling it would make the branch un-findable by its name; rejecting
// is the honest, safe contract. Returns the normalized (lowercased) fragment.
//
// THIS IS THE SQL-IDENTIFIER-INJECTION GUARD. The returned value is interpolated
// into branchSchema(), which is interpolated into CREATE SCHEMA DDL (identifiers
// cannot be bind params). branching_test.go pins this against meta-char inputs.
func sanitizeBranchName(name string) (string, error) {
	name = strings.TrimSpace(strings.ToLower(name))
	if name == "" || len(name) > 40 {
		return "", ErrInvalidBranchName
	}
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
			// ok
		default:
			// Any meta char (';', ' ', '"', '-', etc.) is a hard reject — this is
			// the injection wall, not a best-effort cleanup.
			return "", ErrInvalidBranchName
		}
	}
	// A branch name that is ALL underscores trims to empty -> not a usable schema
	// suffix; reject it too.
	if strings.Trim(name, "_") == "" {
		return "", ErrInvalidBranchName
	}
	return name, nil
}

// branchSchema derives the Postgres schema name a branch's clone lives in. Both
// inputs are pre-sanitized — parentSchema by tenants.TenantSchema (already
// `tenant_<frag>`), branchName by sanitizeBranchName ([a-z0-9_]) — so the result
// is a safe identifier. Shape: <parentSchema>_br_<branchName>, truncated so the
// whole thing stays inside Postgres's 63-byte identifier limit.
func branchSchema(parentSchema, branchName string) string {
	const sep = "_br_"
	s := parentSchema + sep + branchName
	if len(s) > 63 {
		s = s[:63]
	}
	return s
}

// resolveParentSchema resolves the per-tenant schema a branch forks from, reusing
// the SINGLE-SOURCE sanitizer tenants.TenantSchema (the same schema name a mount
// was provisioned under). Returns ErrNoMount when the id sanitizes to empty.
func resolveParentSchema(tenantID string) (string, error) {
	schema := tenants.TenantSchema(tenantID)
	if schema == "" {
		return "", fmt.Errorf("branching: tenant id sanitizes to an empty schema")
	}
	return schema, nil
}
