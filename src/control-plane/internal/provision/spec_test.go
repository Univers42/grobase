package provision

import (
	"strings"
	"testing"
)

func TestNormalizeDefaults(t *testing.T) {
	s := StackSpec{Tenant: "  T-Acme  "}
	s.Normalize()

	if s.Tenant != "t-acme" {
		t.Errorf("Tenant = %q, want lowercased/trimmed t-acme", s.Tenant)
	}
	if s.Name != "t-acme" {
		t.Errorf("Name defaulted to %q, want slug", s.Name)
	}
	if s.Plan != D().Plan {
		t.Errorf("Plan = %q, want default %q", s.Plan, D().Plan)
	}
	if s.Isolation != D().Isolation {
		t.Errorf("Isolation = %q, want default %q", s.Isolation, D().Isolation)
	}
	if len(s.Keys) != 1 || s.Keys[0].Name != D().KeyName {
		t.Fatalf("Keys = %+v, want one default key", s.Keys)
	}
	if len(s.Keys[0].Scopes) != len(D().KeyScopes) {
		t.Errorf("default key scopes = %v, want %v", s.Keys[0].Scopes, D().KeyScopes)
	}
}

func TestNormalizeIdempotent(t *testing.T) {
	s := StackSpec{Tenant: "acme", Engines: []EngineSpec{{Engine: "PostgreSQL", Name: "db", ConnectionString: "x"}}}
	s.Normalize()
	first := s
	s.Normalize()
	if s.Engines[0].Engine != "postgresql" || s.Engines[0].Isolation != D().MountIsolation {
		t.Fatalf("engine not normalized: %+v", s.Engines[0])
	}
	if first.Tenant != s.Tenant || first.Engines[0].Isolation != s.Engines[0].Isolation {
		t.Error("Normalize is not idempotent")
	}
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name    string
		spec    StackSpec
		wantErr bool
	}{
		{"ok", StackSpec{Tenant: "acme", Keys: []KeySpec{{Name: "default"}}}, false},
		{"bad slug uppercase", StackSpec{Tenant: "Acme"}, true},
		{"bad slug too short", StackSpec{Tenant: "a"}, true},
		{"mount missing dsn", StackSpec{Tenant: "acme", Engines: []EngineSpec{{Engine: "redis", Name: "r"}}}, true},
		{"role missing name", StackSpec{Tenant: "acme", Roles: []RoleSpec{{Name: ""}}}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := c.spec.Validate(); (err != nil) != c.wantErr {
				t.Errorf("Validate() err = %v, wantErr %v", err, c.wantErr)
			}
		})
	}
}

func TestCompileExpandsAndTopoSorts(t *testing.T) {
	s := StackSpec{
		Tenant:      "acme",
		OwnerUserID: "00000000-0000-4000-8000-000000000001",
		Keys:        []KeySpec{{Name: "default", Scopes: []string{"read"}}},
		Roles: []RoleSpec{{
			Name:     "editor",
			Policies: []PolicySpec{{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow"}},
		}},
		Engines: []EngineSpec{
			{Engine: "redis", Name: "cache", ConnectionString: "redis://x", Isolation: "shared_rls"},
			{Engine: "postgresql", Name: "main", ConnectionString: "postgres://x", Isolation: "schema_per_tenant"},
		},
	}
	s.Normalize()
	ds := s.Compile()

	// Expect: tenant, key, role, policy, 2 mounts, 1 schema = 7 resources.
	if len(ds.Resources) != 7 {
		t.Fatalf("got %d resources, want 7: %+v", len(ds.Resources), ds.Resources)
	}
	// Topo order: Kind must be non-decreasing.
	for i := 1; i < len(ds.Resources); i++ {
		if ds.Resources[i].Kind < ds.Resources[i-1].Kind {
			t.Fatalf("resources not topo-sorted at %d: %v then %v", i, ds.Resources[i-1].Kind, ds.Resources[i].Kind)
		}
	}
	// First must be the tenant.
	if ds.Resources[0].Kind != KindTenant {
		t.Errorf("first resource kind = %v, want KindTenant", ds.Resources[0].Kind)
	}
}

func TestCompileDedupesByIdentity(t *testing.T) {
	s := StackSpec{
		Tenant: "acme",
		Keys:   []KeySpec{{Name: "default"}, {Name: "default"}}, // dup
		Engines: []EngineSpec{
			{Engine: "redis", Name: "cache", ConnectionString: "x"},
			{Engine: "redis", Name: "cache", ConnectionString: "x"}, // dup
		},
	}
	s.Normalize()
	ds := s.Compile()
	// tenant + 1 key + 1 mount = 3 (dups collapsed).
	if len(ds.Resources) != 3 {
		t.Fatalf("dedupe failed: got %d resources %+v", len(ds.Resources), ds.Resources)
	}
}

func TestPolicyKeyStableUnderReorder(t *testing.T) {
	a := PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"select", "insert"}, Effect: "allow", Conditions: map[string]any{"owner_only": true, "x": 1}}
	b := PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"insert", "select"}, Effect: "allow", Conditions: map[string]any{"x": 1, "owner_only": true}}
	if PolicyKey("role:acme:user", a) != PolicyKey("role:acme:user", b) {
		t.Error("PolicyKey must be stable under action/condition reorder")
	}
}

func TestNamespacedRoleName(t *testing.T) {
	got := NamespacedRoleName(RoleKey("acme", "editor"))
	if got != "acme:editor" {
		t.Errorf("NamespacedRoleName = %q, want acme:editor", got)
	}
}

// TestValidateRejectsMalformedRoleName pins fix #5: role names must match the
// slug charset family, so a name can't carry the `:` namespace separator, `*`,
// or whitespace.
func TestValidateRejectsMalformedRoleName(t *testing.T) {
	bad := []string{"has:colon", "has space", "Upper", "*", "has*star", strings.Repeat("a", 64)}
	for _, name := range bad {
		s := StackSpec{Tenant: "acme", Roles: []RoleSpec{{Name: name}}}
		if err := s.Validate(); err == nil {
			t.Errorf("Validate accepted malformed role name %q, want error", name)
		}
	}
	ok := StackSpec{Tenant: "acme", Roles: []RoleSpec{{Name: "editor-1_x"}}}
	if err := ok.Validate(); err != nil {
		t.Errorf("Validate rejected well-formed role name: %v", err)
	}
}

// TestValidateEnforcesArrayBounds pins fix #3: per-stack cardinalities are capped
// so a single request can't fan out unbounded downstream writes.
func TestValidateEnforcesArrayBounds(t *testing.T) {
	engines := make([]EngineSpec, MaxEngines+1)
	for i := range engines {
		engines[i] = EngineSpec{Engine: "postgresql", Name: "m", ConnectionString: "x"}
	}
	if err := (StackSpec{Tenant: "acme", Engines: engines}).Validate(); err == nil {
		t.Error("Validate must reject > MaxEngines engines")
	}

	keys := make([]KeySpec, MaxKeys+1)
	for i := range keys {
		keys[i] = KeySpec{Name: "k"}
	}
	if err := (StackSpec{Tenant: "acme", Keys: keys}).Validate(); err == nil {
		t.Error("Validate must reject > MaxKeys keys")
	}

	roles := make([]RoleSpec, MaxRoles+1)
	for i := range roles {
		roles[i] = RoleSpec{Name: "user"}
	}
	if err := (StackSpec{Tenant: "acme", Roles: roles}).Validate(); err == nil {
		t.Error("Validate must reject > MaxRoles roles")
	}

	pols := make([]PolicySpec, MaxPoliciesPerRole+1)
	for i := range pols {
		pols[i] = PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow"}
	}
	if err := (StackSpec{Tenant: "acme", Roles: []RoleSpec{{Name: "user", Policies: pols}}}).Validate(); err == nil {
		t.Error("Validate must reject > MaxPoliciesPerRole policies under a role")
	}

	// At-the-limit must PASS (boundary check).
	atLimit := make([]EngineSpec, MaxEngines)
	for i := range atLimit {
		atLimit[i] = EngineSpec{Engine: "postgresql", Name: "m", ConnectionString: "x"}
	}
	if err := (StackSpec{Tenant: "acme", Engines: atLimit}).Validate(); err != nil {
		t.Errorf("Validate must accept exactly MaxEngines engines: %v", err)
	}
}

// TestPolicyContentHashCanonicalJSONConditions pins fix #6: the conditions
// portion of the identity hash is derived from the SAME canonical JSON bound to
// $5::jsonb, so it is stable under key reorder and nested values.
func TestPolicyContentHashCanonicalJSONConditions(t *testing.T) {
	a := PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow",
		Conditions: map[string]any{"owner_only": true, "tier": "gold", "nested": map[string]any{"a": 1, "b": 2}}}
	b := PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow",
		Conditions: map[string]any{"nested": map[string]any{"b": 2, "a": 1}, "tier": "gold", "owner_only": true}}
	if PolicyKey("role:acme:user", a) != PolicyKey("role:acme:user", b) {
		t.Error("policy identity must be stable under condition key reorder (canonical JSON)")
	}

	// A genuinely different condition value must change the identity.
	c := PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow",
		Conditions: map[string]any{"owner_only": false}}
	d := PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow",
		Conditions: map[string]any{"owner_only": true}}
	if PolicyKey("role:acme:user", c) == PolicyKey("role:acme:user", d) {
		t.Error("policy identity must differ when a condition value differs")
	}

	// nil vs empty-map conditions must collapse to the same identity ("{}").
	e := PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow", Conditions: nil}
	f := PolicySpec{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow", Conditions: map[string]any{}}
	if PolicyKey("role:acme:user", e) != PolicyKey("role:acme:user", f) {
		t.Error("nil and empty conditions must hash identically")
	}
}
