package provision

import "strings"

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
