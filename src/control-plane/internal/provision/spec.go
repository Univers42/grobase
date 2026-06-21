/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   spec.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:52 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:53 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

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
	"regexp"
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

// defaultSpec builds the active defaults fresh. It is the ONE place every
// provisioning literal lives — replacing the former package-level singleton, so
// the compiled regexes are no longer shared mutable state. Built on each call
// (provisioning is API-rate, not a hot path); field values/patterns are
// byte-identical to the prior literal.
//
// RoleNamePattern shares the slug charset family (lowercase alnum + _ -),
// bounded to <=63 chars, so a name can never carry `:` (the namespace
// separator), `*`, or whitespace, nor be unbounded. Defense-in-depth: the slug
// prefix already isolates tenants; this keeps the un-prefixed name well-formed.
func defaultSpec() Defaults {
	return Defaults{
		SlugPattern:     regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{1,62}$`),
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
		SupportedEngines:        defaultSupportedEngines(),
		SupportedMountIsolation: defaultSupportedMountIsolation(),
	}
}

// defaultSupportedEngines is the set of engines provisioning supports by default.
func defaultSupportedEngines() map[string]bool {
	return map[string]bool{
		"postgresql": true, "mysql": true, "redis": true,
		"mongodb": true, "sqlite": true,
	}
}

// defaultSupportedMountIsolation lists the isolation models a reconcile can
// realise. db_per_tenant is intentionally absent: the data plane cannot create a
// dedicated database from a control-plane reconcile, so it must surface as
// "unsupported" rather than silently succeed.
func defaultSupportedMountIsolation() map[string]bool {
	return map[string]bool{
		"shared_rls":        true,
		"schema_per_tenant": true,
	}
}

// D returns the active defaults (read-only view).
func D() Defaults { return defaultSpec() }

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
