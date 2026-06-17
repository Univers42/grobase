package branching

import (
	"errors"
	"strings"
	"testing"
)

// TestGuardIsolation pins the Track-E DB-branching scope: ONLY schema_per_tenant
// is branchable (it clones a schema); shared_rls, db_per_tenant, tenant_owned (and
// anything else) are DEFERRED with ErrIsolationDeferred (the handler maps it to
// 400). This is the structural wall the migration 055 CHECK also enforces.
func TestGuardIsolation(t *testing.T) {
	if err := guardIsolation("schema_per_tenant"); err != nil {
		t.Fatalf("guardIsolation(schema_per_tenant) = %v, want nil (branching must support it)", err)
	}
	deferred := []string{"shared_rls", "db_per_tenant", "tenant_owned", "", "bogus"}
	for _, iso := range deferred {
		err := guardIsolation(iso)
		if !errors.Is(err, ErrIsolationDeferred) {
			t.Fatalf("guardIsolation(%q) = %v, want ErrIsolationDeferred", iso, err)
		}
	}
}

// TestDeferredMessageMentionsDeferred guards the gate's body assertion: the 400's
// message must contain "deferred" (the m113 gate greps for it).
func TestDeferredMessageMentionsDeferred(t *testing.T) {
	if !strings.Contains(strings.ToLower(ErrIsolationDeferred.Error()), "deferred") {
		t.Fatalf("ErrIsolationDeferred message %q must contain 'deferred'", ErrIsolationDeferred.Error())
	}
}

// TestSanitizeBranchName is the LOAD-BEARING SQL-identifier-injection test. The
// branch name flows into `CREATE SCHEMA <branch_schema>` (an identifier, never a
// bind param), so a name carrying a SQL meta char MUST be REJECTED — not silently
// rewritten — or a caller could smuggle `x; DROP SCHEMA …` into DDL. This test
// pins both halves of the contract: safe names normalize+pass, dangerous names
// hard-fail with ErrInvalidBranchName.
func TestSanitizeBranchName(t *testing.T) {
	// Safe names: accepted and lowercased.
	safe := map[string]string{
		"staging":     "staging",
		"preview_2":   "preview_2",
		"FeatureX":    "featurex",
		"a":           "a",
		"my_branch_1": "my_branch_1",
	}
	for in, want := range safe {
		got, err := sanitizeBranchName(in)
		if err != nil {
			t.Fatalf("sanitizeBranchName(%q) errored %v, want %q", in, err, want)
		}
		if got != want {
			t.Fatalf("sanitizeBranchName(%q) = %q, want %q", in, got, want)
		}
	}

	// Dangerous / invalid names: REJECTED (the injection wall fires).
	bad := []string{
		"",                       // empty
		"   ",                    // whitespace-only
		"x; drop schema tenant_a", // classic injection
		"x DROP SCHEMA",          // space
		`x"`,                     // quote
		"x'y",                    // single quote
		"x-y",                    // hyphen (not in [a-z0-9_])
		"x.y",                    // dot
		"x/y",                    // slash
		"x\\y",                   // backslash
		"x;y",                    // semicolon
		"x(y)",                   // parens
		"___",                    // all underscores -> trims to empty
		strings.Repeat("a", 41),  // too long (>40)
	}
	for _, in := range bad {
		got, err := sanitizeBranchName(in)
		if !errors.Is(err, ErrInvalidBranchName) {
			t.Fatalf("sanitizeBranchName(%q) = (%q, %v), want ErrInvalidBranchName (INJECTION WALL)", in, got, err)
		}
	}
}

// TestBranchSchemaIsSafeAndBounded pins that the derived branch schema is a safe,
// bounded identifier: it is built only from two already-sanitized fragments
// (parent schema + sanitized branch name) joined by "_br_", and truncated to
// Postgres's 63-byte identifier limit. A name that passed the sanitizer can never
// produce an unsafe schema string.
func TestBranchSchemaIsSafeAndBounded(t *testing.T) {
	parent := "tenant_acme"
	name, err := sanitizeBranchName("staging")
	if err != nil {
		t.Fatalf("setup: sanitizeBranchName errored %v", err)
	}
	got := branchSchema(parent, name)
	if got != "tenant_acme_br_staging" {
		t.Fatalf("branchSchema = %q, want tenant_acme_br_staging", got)
	}
	for _, r := range got {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
		default:
			t.Fatalf("branchSchema produced an out-of-class char %q in %q", r, got)
		}
	}
	// 63-byte bound: a long (but sanitizer-valid) name must not overflow.
	longName, err := sanitizeBranchName(strings.Repeat("a", 40))
	if err != nil {
		t.Fatalf("setup: long name should be valid (40 chars), got %v", err)
	}
	longSchema := branchSchema("tenant_"+strings.Repeat("b", 50), longName)
	if len(longSchema) > 63 {
		t.Fatalf("branchSchema len = %d, want <= 63 (Postgres identifier limit)", len(longSchema))
	}
}
