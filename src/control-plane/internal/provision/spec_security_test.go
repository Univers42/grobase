/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   spec_security_test.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:46 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:47 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package provision

import (
	"strings"
	"testing"
)

// validSpec builds a minimal Normalized+valid StackSpec the tests mutate to
// exercise one rejection at a time.
func validSpec() StackSpec {
	s := StackSpec{Tenant: "acme", OwnerUserID: "u1"}
	s.Normalize()
	return s
}

// TestValidate_MaliciousTenantSlugs is a hardening table: injection-shaped,
// boundary, unicode, and malformed tenant slugs must be REJECTED (the slug is the
// per-tenant isolation namespace — a `:` or `*` here would let a tenant escape
// its role namespace). Valid slugs must pass.
func TestValidate_MaliciousTenantSlugs(t *testing.T) {
	cases := []struct {
		name string
		slug string
		ok   bool
	}{
		{"simple", "acme", true},
		{"with_dash", "acme-corp", true},
		{"with_underscore", "acme_corp", true},
		{"alnum", "tenant42", true},
		{"min_two_chars", "ab", true},
		{"max_63_chars", "a" + strings.Repeat("b", 62), true},
		{"single_char_too_short", "a", false},
		{"too_long_64", "a" + strings.Repeat("b", 63), false},
		{"empty", "", false},
		// "ACME" is lowercased by Normalize() -> "acme" (valid). The slug PATTERN
		// itself rejects uppercase, but Normalize runs first, so the post-normalize
		// spec is accepted. Asserting that documented flow here.
		{"uppercase_lowercased_to_valid", "ACME", true},
		{"leading_dash", "-acme", false},
		{"leading_underscore", "_acme", false},
		{"colon_namespace_escape", "acme:admin", false},
		{"star_wildcard", "acme*", false},
		{"space", "acme corp", false},
		{"slash", "acme/admin", false},
		{"dot", "acme.corp", false},
		{"sql_injection", "acme'; DROP TABLE tenants;--", false},
		{"newline", "acme\nevil", false},
		{"nul", "acme\x00", false},
		{"unicode", "acmé", false},
		{"at_sign", "acme@corp", false},
		{"percent", "acme%20", false},
		{"backtick", "acme`id`", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := StackSpec{Tenant: c.slug, OwnerUserID: "u1"}
			s.Normalize() // Normalize lowercases+trims; Validate is the gate
			err := s.Validate()
			if c.ok && err != nil {
				t.Fatalf("slug %q should be valid, got %v", c.slug, err)
			}
			if !c.ok && err == nil {
				t.Fatalf("slug %q should be rejected", c.slug)
			}
		})
	}
}

// TestValidate_MaliciousRoleNames proves role names sharing the slug charset are
// enforced: a `:` (the namespace separator), `*`, whitespace, or over-length name
// is rejected so a role can never carry the separator that isolates tenants.
func TestValidate_MaliciousRoleNames(t *testing.T) {
	cases := []struct {
		name string
		role string
		ok   bool
	}{
		{"simple", "user", true},
		{"admin", "admin", true},
		{"with_dash", "read-only", true},
		{"with_underscore", "power_user", true},
		{"single_char", "a", true},
		{"max_63", "a" + strings.Repeat("b", 62), true},
		{"too_long_64", "a" + strings.Repeat("b", 63), false},
		{"colon_namespace", "tenant:admin", false},
		{"star", "admin*", false},
		{"space", "power user", false},
		{"uppercase", "Admin", false},
		{"leading_dash", "-admin", false},
		{"sql", "admin'--", false},
		{"newline", "admin\nroot", false},
		{"nul", "admin\x00", false},
		{"unicode", "admín", false},
		{"slash", "admin/root", false},
		{"dot_path", "../admin", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := validSpec()
			s.Roles = []RoleSpec{{Name: c.role}}
			s.Normalize() // lowercases the role name
			// uppercase becomes valid after Normalize lowercases it; so test the
			// RAW pattern intent by checking against the normalized form.
			err := s.Validate()
			if c.name == "uppercase" {
				// Normalize lowercases "Admin" -> "admin", which IS valid; that is
				// the intended behavior, so assert it passes post-normalize.
				if err != nil {
					t.Fatalf("uppercase role is lowercased by Normalize and should pass, got %v", err)
				}
				return
			}
			if c.ok && err != nil {
				t.Fatalf("role %q should be valid, got %v", c.role, err)
			}
			if !c.ok && err == nil {
				t.Fatalf("role %q should be rejected", c.role)
			}
		})
	}
}

// TestValidate_ArrayCardinalityDoS proves the fan-out guard: arrays at/under the
// cap pass, one-over the cap is rejected. An unbounded array would let one
// request spawn unbounded downstream writes.
func TestValidate_ArrayCardinalityDoS(t *testing.T) {
	t.Run("engines_at_cap", func(t *testing.T) {
		s := validSpec()
		s.Engines = make([]EngineSpec, MaxEngines)
		for i := range s.Engines {
			s.Engines[i] = EngineSpec{Engine: "postgresql", Name: "m", ConnectionString: "dsn"}
		}
		if err := s.Validate(); err != nil {
			t.Fatalf("exactly MaxEngines must pass, got %v", err)
		}
	})
	t.Run("engines_over_cap", func(t *testing.T) {
		s := validSpec()
		s.Engines = make([]EngineSpec, MaxEngines+1)
		for i := range s.Engines {
			s.Engines[i] = EngineSpec{Engine: "postgresql", Name: "m", ConnectionString: "dsn"}
		}
		if err := s.Validate(); err == nil {
			t.Fatal("MaxEngines+1 must be rejected (DoS fan-out guard)")
		}
	})
	t.Run("keys_over_cap", func(t *testing.T) {
		s := validSpec()
		s.Keys = make([]KeySpec, MaxKeys+1)
		for i := range s.Keys {
			s.Keys[i] = KeySpec{Name: "k"}
		}
		if err := s.Validate(); err == nil {
			t.Fatal("MaxKeys+1 must be rejected")
		}
	})
	t.Run("roles_over_cap", func(t *testing.T) {
		s := validSpec()
		s.Roles = make([]RoleSpec, MaxRoles+1)
		for i := range s.Roles {
			s.Roles[i] = RoleSpec{Name: "user"}
		}
		if err := s.Validate(); err == nil {
			t.Fatal("MaxRoles+1 must be rejected")
		}
	})
	t.Run("policies_per_role_over_cap", func(t *testing.T) {
		s := validSpec()
		pols := make([]PolicySpec, MaxPoliciesPerRole+1)
		for i := range pols {
			pols[i] = PolicySpec{ResourceType: "t", ResourceName: "n", Actions: []string{"select"}, Effect: "allow"}
		}
		s.Roles = []RoleSpec{{Name: "user", Policies: pols}}
		if err := s.Validate(); err == nil {
			t.Fatal("MaxPoliciesPerRole+1 must be rejected")
		}
	})
	t.Run("policies_per_role_at_cap", func(t *testing.T) {
		s := validSpec()
		pols := make([]PolicySpec, MaxPoliciesPerRole)
		for i := range pols {
			pols[i] = PolicySpec{ResourceType: "t", ResourceName: "n", Actions: []string{"select"}, Effect: "allow"}
		}
		s.Roles = []RoleSpec{{Name: "user", Policies: pols}}
		if err := s.Validate(); err != nil {
			t.Fatalf("exactly MaxPoliciesPerRole must pass, got %v", err)
		}
	})
}

// TestValidate_RequiredEngineFields proves a mount missing engine/name/DSN is
// rejected — an empty DSN would otherwise mount nothing or, worse, a default.
func TestValidate_RequiredEngineFields(t *testing.T) {
	cases := []struct {
		name string
		e    EngineSpec
	}{
		{"missing_engine", EngineSpec{Name: "m", ConnectionString: "dsn"}},
		{"missing_name", EngineSpec{Engine: "postgresql", ConnectionString: "dsn"}},
		{"missing_dsn", EngineSpec{Engine: "postgresql", Name: "m"}},
		{"all_empty", EngineSpec{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := validSpec()
			s.Engines = []EngineSpec{c.e}
			s.Normalize()
			if err := s.Validate(); err == nil {
				t.Fatalf("engine %+v must be rejected", c.e)
			}
		})
	}
}

// TestPolicyContentHash_ABAC_Stability proves the ABAC policy identity is stable
// under action reorder and condition key-order (so a re-declared policy dedupes),
// but DIVERGES on any semantic change (effect flip, resource change, condition
// value change). A drifting identity would let a re-run insert duplicate ABAC
// rows or, worse, miss that an effect flipped from allow→deny.
func TestPolicyContentHash_ABAC_Stability(t *testing.T) {
	base := PolicySpec{
		ResourceType: "table",
		ResourceName: "orders",
		Actions:      []string{"select", "insert"},
		Effect:       "allow",
		Priority:     0,
		Conditions:   map[string]any{"owner_only": true, "tenant": "acme"},
	}
	h := policyContentHash(base)

	t.Run("action_reorder_same_identity", func(t *testing.T) {
		p := base
		p.Actions = []string{"insert", "select"}
		if policyContentHash(p) != h {
			t.Fatal("action order must not change policy identity")
		}
	})
	t.Run("condition_key_order_same_identity", func(t *testing.T) {
		p := base
		p.Conditions = map[string]any{"tenant": "acme", "owner_only": true}
		if policyContentHash(p) != h {
			t.Fatal("condition key order must not change policy identity")
		}
	})
	diffs := []struct {
		name  string
		apply func(p *PolicySpec)
	}{
		{"effect_flip_allow_to_deny", func(p *PolicySpec) { p.Effect = "deny" }},
		{"resource_type_change", func(p *PolicySpec) { p.ResourceType = "view" }},
		{"resource_name_change", func(p *PolicySpec) { p.ResourceName = "invoices" }},
		{"add_action", func(p *PolicySpec) { p.Actions = []string{"select", "insert", "delete"} }},
		{"drop_action", func(p *PolicySpec) { p.Actions = []string{"select"} }},
		{"priority_change", func(p *PolicySpec) { p.Priority = 5 }},
		{"condition_value_change", func(p *PolicySpec) { p.Conditions = map[string]any{"owner_only": false, "tenant": "acme"} }},
		{"condition_add_key", func(p *PolicySpec) {
			p.Conditions = map[string]any{"owner_only": true, "tenant": "acme", "region": "eu"}
		}},
		{"condition_drop_key", func(p *PolicySpec) { p.Conditions = map[string]any{"owner_only": true} }},
	}
	for _, d := range diffs {
		t.Run(d.name, func(t *testing.T) {
			p := base
			d.apply(&p)
			if policyContentHash(p) == h {
				t.Fatalf("semantic change %s must change the policy identity", d.name)
			}
		})
	}
}

// TestCanonicalConditionsJSON_ABAC proves ABAC condition canonicalization: nil
// and empty map both render "{}", key order is stable, and a value change
// diverges. This is the exact byte form bound to $5::jsonb — drift here would
// store a different condition than the dedup hash assumes.
func TestCanonicalConditionsJSON_ABAC(t *testing.T) {
	t.Run("nil_is_empty_object", func(t *testing.T) {
		if string(canonicalConditionsJSON(nil)) != "{}" {
			t.Fatalf("nil conditions must canonicalize to {}, got %s", canonicalConditionsJSON(nil))
		}
	})
	t.Run("empty_is_empty_object", func(t *testing.T) {
		if string(canonicalConditionsJSON(map[string]any{})) != "{}" {
			t.Fatal("empty map must canonicalize to {}")
		}
	})
	t.Run("key_order_stable", func(t *testing.T) {
		a := canonicalConditionsJSON(map[string]any{"b": 2, "a": 1})
		b := canonicalConditionsJSON(map[string]any{"a": 1, "b": 2})
		if string(a) != string(b) {
			t.Fatalf("key order must not change canonical JSON: %s vs %s", a, b)
		}
	})
	t.Run("value_change_diverges", func(t *testing.T) {
		a := canonicalConditionsJSON(map[string]any{"owner_only": true})
		b := canonicalConditionsJSON(map[string]any{"owner_only": false})
		if string(a) == string(b) {
			t.Fatal("a condition value change must change the canonical JSON")
		}
	})
}

// TestPolicyKey_NamespaceIsolation proves policy/role identity keys are bound to
// the tenant slug, so two tenants declaring the same logical role/policy get
// DISTINCT identities — the cross-tenant collision wall on the global
// UNIQUE(roles.name) constraint.
func TestPolicyKey_NamespaceIsolation(t *testing.T) {
	p := PolicySpec{ResourceType: "table", ResourceName: "x", Actions: []string{"select"}, Effect: "allow"}
	k1 := PolicyKey(RoleKey("tenant-a", "admin"), p)
	k2 := PolicyKey(RoleKey("tenant-b", "admin"), p)
	if k1 == k2 {
		t.Fatal("same policy under two tenants must have distinct identity keys (namespace isolation)")
	}
	if RoleKey("tenant-a", "admin") == RoleKey("tenant-b", "admin") {
		t.Fatal("role keys must be tenant-namespaced")
	}
	// NamespacedRoleName round-trips the DB name out of the key.
	if got := NamespacedRoleName(RoleKey("tenant-a", "admin")); got != "tenant-a:admin" {
		t.Fatalf("NamespacedRoleName = %q, want tenant-a:admin", got)
	}
}
