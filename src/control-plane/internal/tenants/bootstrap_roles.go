package tenants

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

// isUUID validates a user id before it is cast to ::uuid for an ABAC role
// assignment, so a non-UUID owner_user_id is skipped cleanly rather than
// surfacing a Postgres cast error.
func isUUID(s string) bool {
	// perf: regex compiled per call — bootstrap path (API-rate, not hot).
	uuidRe := regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	return uuidRe.MatchString(s)
}

// seedDefaultRole ensures the tenant owner holds a baseline ABAC role, via the
// single PermissionEngine seam (one role implementation shared with the
// reconciler). It creates a SLUG-NAMESPACED role (`<slug>:<role>`) so two
// tenants requesting the same logical role do not collide on the global
// UNIQUE(roles.name) — the prior implementation could only assign an existing
// global role for exactly this reason. The role gets the baseline owner-scoped
// CRUD policy (Defaults().RolePolicy) and is granted to the owner.
//
// Idempotent: re-running re-uses the role/policy/assignment (no duplicate rows).
// Returns the namespaced role name actually assigned.
func (s *Service) seedDefaultRole(ctx context.Context, slug, ownerUserID, requestedRole string) (string, error) {
	if !isUUID(ownerUserID) {
		return "", fmt.Errorf("owner_user_id %q is not a UUID; ABAC role not seeded", ownerUserID)
	}
	roleName := strings.TrimSpace(requestedRole)
	if roleName == "" {
		roleName = provision.D().RoleName
	}
	spec := provision.RoleSpec{
		Name:     strings.ToLower(roleName),
		Policies: []provision.PolicySpec{provision.D().RolePolicy},
	}
	roleID, _, err := s.perm.EnsureRole(ctx, slug, spec)
	if err != nil {
		return "", err
	}
	if err := s.ensureRolePolicies(ctx, roleID, spec.Policies); err != nil {
		return "", err
	}
	namespaced := provision.NamespacedRoleName(provision.RoleKey(slug, spec.Name))
	if err := s.perm.AssignRole(ctx, ownerUserID, namespaced); err != nil {
		return "", err
	}
	return namespaced, nil
}

// ensureRolePolicies idempotently ensures every policy on a role.
func (s *Service) ensureRolePolicies(ctx context.Context, roleID string, policies []provision.PolicySpec) error {
	for _, p := range policies {
		if _, perr := s.perm.EnsurePolicy(ctx, roleID, p); perr != nil {
			return perr
		}
	}
	return nil
}

// defaultKeyName trims the requested name, defaulting to "default" when empty.
func defaultKeyName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "default"
	}
	return name
}
