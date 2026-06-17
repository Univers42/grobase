// Package provision is the declarative provisioning brain for the control
// plane. It turns a typed StackSpec (the SINGLE source of truth for a tenant's
// desired shape) into a DesiredState of identity-keyed resources, then a
// Reconciler walks those resources in a fixed topological order and applies each
// one with a per-resource find-or-ensure: every downstream write is idempotent
// (find existing → no-op, else create). There is no batched observe→diff→apply
// phase — convergence is achieved one resource at a time, so a re-run of a
// converged stack produces zero downstream writes.
//
// Design (mandated):
//   - NO hardcoding in logic: every literal lives in Defaults(); Normalize()
//     stamps the spec; Compile() expands it. Reconcile reads only the compiled
//     resources, never bare constants.
//   - DSA: Compile dedupes resources via an O(n) hash-set keyed by resource
//     identity (Resource.Key), and apply walks a fixed step DAG ordered by
//     Resource.Kind ordinals so dependents always follow prerequisites.
package provision

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Defaults is the ONE place every provisioning literal lives. Reconcile/Compile
// logic must read from here (or from a Normalized spec) — never embed a literal.
type Defaults struct {
	SlugPattern      *regexp.Regexp
	RoleNamePattern  *regexp.Regexp // role names: slug-family charset, bounded length
	Isolation        string         // tenant-level default isolation strategy
	MountIsolation   string         // per-mount default isolation strategy
	Plan             string         // default billing plan
	KeyName          string         // default API key name
	KeyScopes        []string       // default API key scopes
	RoleName         string         // default seed role name (un-namespaced base)
	RolePolicy       PolicySpec
	SupportedEngines map[string]bool
	// Isolation strategies the data plane can actually realise. A mount asking
	// for anything else compiles but reconciles to status "unsupported".
	SupportedMountIsolation map[string]bool
}

// defaults is the package-singleton. Exposed via D() so tests can read it
// without mutating it.
var defaults = Defaults{
	SlugPattern: regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{1,62}$`),
	// Role names share the slug charset family (lowercase alnum + _ -), bounded
	// to <=63 chars, so a name can never carry `:` (the namespace separator),
	// `*`, or whitespace, nor be unbounded. Defense-in-depth: the slug prefix
	// already isolates tenants, this keeps the un-prefixed name well-formed.
	RoleNamePattern: regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,62}$`),
	Isolation:       "shared_rls",
	MountIsolation:  "shared_rls",
	Plan:            "free",
	KeyName:         "default",
	KeyScopes:       []string{"read", "write", "admin"},
	RoleName:        "user",
	RolePolicy: PolicySpec{
		ResourceType: "*",
		ResourceName: "*",
		Actions:      []string{"select", "insert", "update", "delete"},
		Effect:       "allow",
		Priority:     0,
		Conditions:   map[string]any{"owner_only": true},
	},
	SupportedEngines: map[string]bool{
		"postgresql": true, "mysql": true, "redis": true,
		"mongodb": true, "sqlite": true,
	},
	SupportedMountIsolation: map[string]bool{
		"shared_rls":        true,
		"schema_per_tenant": true,
		// db_per_tenant is intentionally NOT here: the data plane cannot
		// realise a dedicated database from a control-plane reconcile, so it
		// must surface as "unsupported" rather than silently succeed.
	},
}

// D returns the active defaults (read-only view).
func D() Defaults { return defaults }

// Resource limits. Centralized (no magic numbers scattered through Validate) so
// the DoS surface — request body size + per-stack array cardinalities — is
// tunable in one place. A spec exceeding any bound is rejected with a 400-class
// validation error rather than fanning out unbounded downstream writes.
const (
	// MaxRequestBodyBytes caps the raw provision request body (1 MiB).
	MaxRequestBodyBytes = 1 << 20
	// MaxEngines bounds data mounts per stack.
	MaxEngines = 16
	// MaxRoles bounds ABAC roles per stack.
	MaxRoles = 32
	// MaxKeys bounds API keys per stack.
	MaxKeys = 8
	// MaxPoliciesPerRole bounds policies declared under a single role.
	MaxPoliciesPerRole = 32
)

// StackSpec is the declarative description of a tenant stack. It is the single
// source of truth: Reconcile derives everything it does from a Normalized,
// Compiled StackSpec.
type StackSpec struct {
	Tenant         string       `json:"tenant"` // slug
	Name           string       `json:"name"`
	OwnerUserID    string       `json:"owner_user_id"`
	Plan           string       `json:"plan"`
	Isolation      string       `json:"isolation"`
	Engines        []EngineSpec `json:"engines"`
	Planes         []string     `json:"planes"`
	Keys           []KeySpec    `json:"keys"`
	Roles          []RoleSpec   `json:"roles"`
	IdempotencyKey string       `json:"idempotency_key"`
}

// EngineSpec is one data mount (engine + name + DSN + isolation).
type EngineSpec struct {
	Engine           string `json:"engine"`
	Name             string `json:"name"`
	ConnectionString string `json:"connection_string"`
	Isolation        string `json:"isolation"`
}

// KeySpec is one API key to ensure for the tenant.
type KeySpec struct {
	Name      string   `json:"name"`
	Scopes    []string `json:"scopes"`
	ExpiresAt string   `json:"expires_at"`
}

// RoleSpec is one ABAC role (with its policies) to ensure for the tenant.
type RoleSpec struct {
	Name        string       `json:"name"`
	Description string       `json:"description"`
	Policies    []PolicySpec `json:"policies"`
}

// PolicySpec is one resource_policies row.
type PolicySpec struct {
	ResourceType string         `json:"resource_type"`
	ResourceName string         `json:"resource_name"`
	Actions      []string       `json:"actions"`
	Effect       string         `json:"effect"`
	Priority     int            `json:"priority"`
	Conditions   map[string]any `json:"conditions"`
}

// Normalize lowercases/defaults the spec so downstream logic never re-derives a
// literal. It is idempotent: Normalize(Normalize(x)) == Normalize(x).
func (s *StackSpec) Normalize() {
	d := defaults
	s.Tenant = strings.ToLower(strings.TrimSpace(s.Tenant))
	if s.Name == "" {
		s.Name = s.Tenant
	}
	if s.Plan == "" {
		s.Plan = d.Plan
	}
	if s.Isolation == "" {
		s.Isolation = d.Isolation
	}
	if len(s.Keys) == 0 {
		s.Keys = []KeySpec{{Name: d.KeyName}}
	}
	for i := range s.Keys {
		if strings.TrimSpace(s.Keys[i].Name) == "" {
			s.Keys[i].Name = d.KeyName
		}
		if len(s.Keys[i].Scopes) == 0 {
			s.Keys[i].Scopes = append([]string(nil), d.KeyScopes...)
		}
	}
	for i := range s.Engines {
		s.Engines[i].Engine = strings.ToLower(strings.TrimSpace(s.Engines[i].Engine))
		if strings.TrimSpace(s.Engines[i].Isolation) == "" {
			s.Engines[i].Isolation = d.MountIsolation
		} else {
			s.Engines[i].Isolation = strings.ToLower(strings.TrimSpace(s.Engines[i].Isolation))
		}
	}
	for i := range s.Roles {
		s.Roles[i].Name = strings.ToLower(strings.TrimSpace(s.Roles[i].Name))
		for j := range s.Roles[i].Policies {
			normalizePolicy(&s.Roles[i].Policies[j], d)
		}
	}
}

func normalizePolicy(p *PolicySpec, d Defaults) {
	if p.ResourceType == "" {
		p.ResourceType = d.RolePolicy.ResourceType
	}
	if p.ResourceName == "" {
		p.ResourceName = d.RolePolicy.ResourceName
	}
	if p.Effect == "" {
		p.Effect = d.RolePolicy.Effect
	}
	if len(p.Actions) == 0 {
		p.Actions = append([]string(nil), d.RolePolicy.Actions...)
	}
}

// Validate enforces the slug + per-resource shape AFTER Normalize. It also caps
// array cardinalities (DoS / fan-out guard) so a single request can never spawn
// an unbounded number of downstream writes.
func (s StackSpec) Validate() error {
	if !defaults.SlugPattern.MatchString(s.Tenant) {
		return fmt.Errorf("tenant must match %s", defaults.SlugPattern.String())
	}
	if len(s.Engines) > MaxEngines {
		return fmt.Errorf("too many engines: %d (max %d)", len(s.Engines), MaxEngines)
	}
	if len(s.Keys) > MaxKeys {
		return fmt.Errorf("too many keys: %d (max %d)", len(s.Keys), MaxKeys)
	}
	if len(s.Roles) > MaxRoles {
		return fmt.Errorf("too many roles: %d (max %d)", len(s.Roles), MaxRoles)
	}
	for i, e := range s.Engines {
		if e.Engine == "" || e.Name == "" || e.ConnectionString == "" {
			return fmt.Errorf("engines[%d]: engine, name and connection_string are required", i)
		}
	}
	for i, k := range s.Keys {
		if strings.TrimSpace(k.Name) == "" {
			return fmt.Errorf("keys[%d]: name is required", i)
		}
	}
	for i, r := range s.Roles {
		if r.Name == "" {
			return fmt.Errorf("roles[%d]: name is required", i)
		}
		if !defaults.RoleNamePattern.MatchString(r.Name) {
			return fmt.Errorf("roles[%d]: name must match %s", i, defaults.RoleNamePattern.String())
		}
		if len(r.Policies) > MaxPoliciesPerRole {
			return fmt.Errorf("roles[%d]: too many policies: %d (max %d)", i, len(r.Policies), MaxPoliciesPerRole)
		}
	}
	return nil
}

// Kind is the topological rank of a resource. Reconcile applies resources in
// ascending Kind, so dependents always come after their prerequisites. This is
// the "fixed topo-ordered step DAG".
type Kind int

const (
	KindTenant Kind = iota
	KindKey
	KindRole
	KindPolicy
	KindMount
	KindSchema
)

// Resource is one identity-keyed unit of desired state. Key is the hash-set
// identity used for Compile-time dedup (and find-or-ensure idempotency); Kind is
// the topo rank used by apply.
type Resource struct {
	Kind    Kind
	Key     string
	RoleRef string // for policies/role-children: which role Key this belongs to
	Key2    string // secondary parent ref (e.g. mount key for a schema)

	// Typed payloads (only the one matching Kind is populated).
	Key3   KeySpec
	Role   RoleSpec
	Policy PolicySpec
	Engine EngineSpec
}

// DesiredState is the compiled, deduped, identity-keyed view of a StackSpec.
// Resources is topo-sorted by Kind so the reconciler can iterate in order.
type DesiredState struct {
	Slug      string
	Name      string
	OwnerUser string
	Plan      string
	Resources []Resource
}

// Compile expands a Normalized+Validated StackSpec into a DesiredState. Engines
// become mount (+ optional schema) resources; roles become role + policy
// resources. Resources are deduped by identity Key and topo-sorted by Kind.
//
// Identity keys (stable, content-derived where needed):
//
//	tenant:<slug>
//	key:<slug>:<name>
//	role:<slug>:<role>
//	policy:<roleKey>:<contentHash>
//	mount:<slug>:<engine>:<name>
//	schema:<slug>:<mountName>
func (s StackSpec) Compile() DesiredState {
	ds := DesiredState{Slug: s.Tenant, Name: s.Name, OwnerUser: s.OwnerUserID, Plan: s.Plan}
	seen := make(map[string]struct{})
	add := func(r Resource) {
		if _, dup := seen[r.Key]; dup {
			return
		}
		seen[r.Key] = struct{}{}
		ds.Resources = append(ds.Resources, r)
	}

	add(Resource{Kind: KindTenant, Key: TenantKey(s.Tenant)})

	for _, k := range s.Keys {
		add(Resource{Kind: KindKey, Key: KeyKey(s.Tenant, k.Name), Key3: k})
	}

	for _, role := range s.Roles {
		roleKey := RoleKey(s.Tenant, role.Name)
		add(Resource{Kind: KindRole, Key: roleKey, Role: role})
		for _, p := range role.Policies {
			add(Resource{
				Kind:    KindPolicy,
				Key:     PolicyKey(roleKey, p),
				RoleRef: roleKey,
				Policy:  p,
			})
		}
	}

	for _, e := range s.Engines {
		mountKey := MountKey(s.Tenant, e.Engine, e.Name)
		add(Resource{Kind: KindMount, Key: mountKey, Engine: e})
		if e.Isolation == "schema_per_tenant" {
			add(Resource{
				Kind:   KindSchema,
				Key:    SchemaKey(s.Tenant, e.Name),
				Key2:   mountKey,
				Engine: e,
			})
		}
	}

	sort.SliceStable(ds.Resources, func(i, j int) bool {
		return ds.Resources[i].Kind < ds.Resources[j].Kind
	})
	return ds
}

// ── Identity-key constructors (single source of the key format) ──────────────

// TenantKey is the identity of the tenant resource.
func TenantKey(slug string) string { return "tenant:" + slug }

// KeyKey is the identity of an API key resource.
func KeyKey(slug, name string) string { return "key:" + slug + ":" + name }

// RoleKey is the identity of a role resource. NOTE: this is also the
// slug-namespaced role NAME stored in public.roles — namespacing dodges the
// global UNIQUE(roles.name) collision between tenants.
func RoleKey(slug, role string) string { return "role:" + slug + ":" + role }

// NamespacedRoleName extracts the DB role name (`<slug>:<role>`) from a RoleKey.
func NamespacedRoleName(roleKey string) string {
	return strings.TrimPrefix(roleKey, "role:")
}

// PolicyKey is the content-keyed identity of a policy under a role.
func PolicyKey(roleKey string, p PolicySpec) string {
	return "policy:" + roleKey + ":" + policyContentHash(p)
}

// MountKey is the identity of a data mount resource.
func MountKey(slug, engine, name string) string {
	return "mount:" + slug + ":" + engine + ":" + name
}

// SchemaKey is the identity of a per-tenant schema resource.
func SchemaKey(slug, mountName string) string {
	return "schema:" + slug + ":" + mountName
}

// policyContentHash is a deterministic digest of a policy's semantic content so
// the same policy re-declared maps to the same identity (idempotent diff). It
// sorts actions so ordering doesn't change identity, and folds conditions in via
// their CANONICAL JSON — the EXACT bytes EnsurePolicy binds to `$5::jsonb`
// (Go marshals map keys sorted). Deriving the identity key and the stored DB
// value from one canonical form avoids drift (e.g. float64-vs-int JSON
// round-tripping, nested-value nondeterminism from the old `%v` formatting).
func policyContentHash(p PolicySpec) string {
	actions := append([]string(nil), p.Actions...)
	sort.Strings(actions)
	var b strings.Builder
	b.WriteString(p.ResourceType)
	b.WriteByte('|')
	b.WriteString(p.ResourceName)
	b.WriteByte('|')
	b.WriteString(strings.Join(actions, ","))
	b.WriteByte('|')
	b.WriteString(p.Effect)
	b.WriteByte('|')
	fmt.Fprintf(&b, "%d|", p.Priority)
	b.Write(canonicalConditionsJSON(p.Conditions))
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:8])
}

// canonicalConditionsJSON returns the canonical JSON for a policy's conditions,
// matching EnsurePolicy's `$5::jsonb` bind byte-for-byte (nil → "{}"; Go's
// encoding/json sorts map keys, giving a stable digest). Marshal of a
// map[string]any never errors, so a failure degrades to "{}" deterministically.
func canonicalConditionsJSON(conds map[string]any) []byte {
	if conds == nil {
		conds = map[string]any{}
	}
	out, err := json.Marshal(conds)
	if err != nil {
		return []byte("{}")
	}
	return out
}
