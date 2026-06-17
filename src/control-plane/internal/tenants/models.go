// Package tenants implements the top-level tenant registry + API key issuance.
//
// A "tenant" is the missing root entity: every other table in the system
// keys off tenant_id but until migration 032 there was no central registry.
// This package owns:
//   - public.tenants       CRUD
//   - public.tenant_api_keys CRUD (with prefix+hash storage)
//   - bootstrap orchestration: tenant row + default ABAC role + first key
package tenants

import (
	"fmt"
	"regexp"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

// Tenant is the public projection of public.tenants.
//
// `ID` is the human-readable slug used by every other table in the system
// as `tenant_id` (signed envelopes, RLS policies, etc.). `UUID` is the
// internal primary key referenced by apps/projects FKs — exposed for
// completeness but most callers should never need it.
type Tenant struct {
	ID          string            `json:"id"`
	UUID        string            `json:"uuid"`
	Name        string            `json:"name"`
	Status      string            `json:"status"`
	Plan        string            `json:"plan"`
	OwnerUserID *string           `json:"owner_user_id"`
	Metadata    map[string]any    `json:"metadata"`
	CreatedAt   string            `json:"created_at"`
	UpdatedAt   string            `json:"updated_at"`
}

// CreateTenantRequest is the POST /v1/tenants body.
type CreateTenantRequest struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Plan        string            `json:"plan"`
	OwnerUserID string            `json:"owner_user_id"`
	Metadata    map[string]any    `json:"metadata"`
}

var idRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{1,62}$`)

// uuidRe validates a user id before it is cast to ::uuid for an ABAC role
// assignment, so a non-UUID owner_user_id is skipped cleanly rather than
// surfacing a Postgres cast error.
var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// Validate enforces the same constraints as the DB CHECK.
func (r CreateTenantRequest) Validate() error {
	if !idRe.MatchString(r.ID) {
		return fmt.Errorf(`id must match ^[a-z0-9][a-z0-9_-]{1,62}$`)
	}
	if r.Name == "" {
		return fmt.Errorf("name is required")
	}
	return nil
}

// UpdateTenantRequest is the PATCH body.
type UpdateTenantRequest struct {
	Name     *string         `json:"name"`
	Plan     *string         `json:"plan"`
	Status   *string         `json:"status"`
	Metadata map[string]any  `json:"metadata"`
}

// APIKey is the redacted view of public.tenant_api_keys.
type APIKey struct {
	ID         string   `json:"id"`
	TenantID   string   `json:"tenant_id"`
	Name       string   `json:"name"`
	KeyPrefix  string   `json:"key_prefix"`
	Scopes     []string `json:"scopes"`
	CreatedAt  string   `json:"created_at"`
	ExpiresAt  *string  `json:"expires_at"`
	LastUsedAt *string  `json:"last_used_at"`
	RevokedAt  *string  `json:"revoked_at"`
}

// IssueKeyRequest is the POST /v1/tenants/:id/keys body.
type IssueKeyRequest struct {
	Name      string   `json:"name"`
	Scopes    []string `json:"scopes"`
	ExpiresAt string   `json:"expires_at"`
}

// IssueKeyResponse returns the full key ONCE. Subsequent reads only expose the
// prefix; clients must store the full key on first receipt.
type IssueKeyResponse struct {
	APIKey
	Key string `json:"key"`
}

// BootstrapRequest is the POST /v1/tenants/:id/bootstrap body.
// Wires up everything a new tenant needs in one call:
//   - default ABAC role with allow-all policy on every resource
//   - first API key
//   - (optional) default mount via the adapter-registry
type BootstrapRequest struct {
	OwnerUserID    string `json:"owner_user_id"`
	DefaultRoleName string `json:"default_role_name"`
	DefaultKeyName  string `json:"default_key_name"`
	SeedRoles       bool   `json:"seed_roles"`
}

// BootstrapResponse summarises what was wired. Idempotent: on re-bootstrap the
// tenant is reused (`created:false`) and an existing key is not re-minted
// (`api_key` omitted, `key_reuse:true`) — mirroring the self-bootstrap path.
type BootstrapResponse struct {
	Tenant   Tenant            `json:"tenant"`
	APIKey   *IssueKeyResponse `json:"api_key,omitempty"`
	Roles    []string          `json:"roles"`
	Created  bool              `json:"created"`
	KeyReuse bool              `json:"key_reuse,omitempty"`
}

// ProvisionRequest is the POST /v1/provision body — a declarative tenant stack.
// It reconciles (idempotently) the tenant + first API key + default ABAC role
// AND a set of data mounts registered in the adapter-registry, in one call.
type ProvisionRequest struct {
	Tenant          string      `json:"tenant"` // slug
	Name            string      `json:"name"`   // display name (defaults to slug)
	Plan            string      `json:"plan"`   // billing plan (default free via StackSpec.Normalize)
	OwnerUserID     string      `json:"owner_user_id"`
	DefaultRoleName string      `json:"default_role_name"`
	DefaultKeyName  string      `json:"default_key_name"`
	SeedRoles       bool        `json:"seed_roles"`
	Mounts          []MountSpec `json:"mounts"`
}

// MountSpec is one data mount to register (engine + name + DSN). The DSN is
// encrypted at rest by the adapter-registry — tenant-control never stores it.
// `isolation` (optional) selects the tenant isolation strategy: "shared_rls"
// (default), "schema_per_tenant" (provision creates `tenant_<slug>`), or
// "db_per_tenant".
type MountSpec struct {
	Engine           string `json:"engine"`
	Name             string `json:"name"`
	ConnectionString string `json:"connection_string"`
	Isolation        string `json:"isolation"`
}

// ProvisionResponse summarises the reconciled state. Idempotent: re-running
// reports created:false / key_reuse:true and already-present mounts as "exists".
type ProvisionResponse struct {
	Tenant   Tenant            `json:"tenant"`
	APIKey   *IssueKeyResponse `json:"api_key,omitempty"`
	KeyReuse bool              `json:"key_reuse,omitempty"`
	Created  bool              `json:"created"`
	Roles    []string          `json:"roles"`
	Mounts   []MountResult     `json:"mounts"`
}

// MountResult is the per-mount reconcile outcome.
type MountResult struct {
	Engine string `json:"engine"`
	Name   string `json:"name"`
	Status string `json:"status"` // created | exists | error
	ID     string `json:"id,omitempty"`
	Schema string `json:"schema,omitempty"` // set when a per-tenant schema was created
	Error  string `json:"error,omitempty"`
}

// Validate checks the provision request shape (the tenant slug + each mount).
func (r ProvisionRequest) Validate() error {
	if !idRe.MatchString(r.Tenant) {
		return fmt.Errorf(`tenant must match ^[a-z0-9][a-z0-9_-]{1,62}$`)
	}
	for i, m := range r.Mounts {
		if m.Engine == "" || m.Name == "" || m.ConnectionString == "" {
			return fmt.Errorf("mounts[%d]: engine, name and connection_string are required", i)
		}
	}
	return nil
}

// Compile maps the legacy declarative ProvisionRequest onto the typed
// provision.StackSpec the reconciler consumes. Backward-compat seam: the old
// JSON body (tenant + mounts + seed_roles + default_*_name) still works, it just
// flows through the new brain. Defaults are left to StackSpec.Normalize so the
// SINGLE source of truth (provision.Defaults) applies — Compile only translates
// shape, it does not inject literals.
func (r ProvisionRequest) Compile() provision.StackSpec {
	spec := provision.StackSpec{
		Tenant:      r.Tenant,
		Name:        r.Name,
		Plan:        r.Plan, // "" → StackSpec.Normalize stamps Defaults().Plan (free)
		OwnerUserID: r.OwnerUserID,
	}
	if r.DefaultKeyName != "" {
		spec.Keys = []provision.KeySpec{{Name: r.DefaultKeyName}}
	}
	if r.SeedRoles {
		role := provision.RoleSpec{
			Name:     r.DefaultRoleName, // "" → Normalize stamps Defaults().RoleName
			Policies: []provision.PolicySpec{provision.D().RolePolicy},
		}
		spec.Roles = []provision.RoleSpec{role}
	}
	for _, m := range r.Mounts {
		spec.Engines = append(spec.Engines, provision.EngineSpec{
			Engine:           m.Engine,
			Name:             m.Name,
			ConnectionString: m.ConnectionString,
			Isolation:        m.Isolation,
		})
	}
	return spec
}

// VerifyKeyRequest is the internal POST /v1/keys/verify body. Used by the
// gateway/proxy to exchange an API key for a tenant identity.
type VerifyKeyRequest struct {
	Key string `json:"key"`
}

// VerifyKeyResponse is the verification result.
type VerifyKeyResponse struct {
	Valid     bool     `json:"valid"`
	TenantID  string   `json:"tenant_id,omitempty"`
	KeyID     string   `json:"key_id,omitempty"`
	Scopes    []string `json:"scopes,omitempty"`
	Reason    string   `json:"reason,omitempty"`
}
