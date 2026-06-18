package provision

import (
	"fmt"
	"strings"
)

// Validate enforces the slug + per-resource shape AFTER Normalize. It also caps
// array cardinalities (DoS / fan-out guard) so a single request can never spawn
// an unbounded number of downstream writes.
func (s StackSpec) Validate() error {
	slugPattern := defaultSpec().SlugPattern
	if !slugPattern.MatchString(s.Tenant) {
		return fmt.Errorf("tenant must match %s", slugPattern.String())
	}
	if err := s.validateCardinality(); err != nil {
		return err
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
	return s.validateRoles()
}

// validateCardinality caps per-stack array sizes (DoS / fan-out guard).
func (s StackSpec) validateCardinality() error {
	if len(s.Engines) > MaxEngines {
		return fmt.Errorf("too many engines: %d (max %d)", len(s.Engines), MaxEngines)
	}
	if len(s.Keys) > MaxKeys {
		return fmt.Errorf("too many keys: %d (max %d)", len(s.Keys), MaxKeys)
	}
	if len(s.Roles) > MaxRoles {
		return fmt.Errorf("too many roles: %d (max %d)", len(s.Roles), MaxRoles)
	}
	return nil
}

// validateRoles enforces each role's name shape and per-role policy cap.
func (s StackSpec) validateRoles() error {
	roleNamePattern := defaultSpec().RoleNamePattern
	for i, r := range s.Roles {
		if r.Name == "" {
			return fmt.Errorf("roles[%d]: name is required", i)
		}
		if !roleNamePattern.MatchString(r.Name) {
			return fmt.Errorf("roles[%d]: name must match %s", i, roleNamePattern.String())
		}
		if len(r.Policies) > MaxPoliciesPerRole {
			return fmt.Errorf("roles[%d]: too many policies: %d (max %d)", i, len(r.Policies), MaxPoliciesPerRole)
		}
	}
	return nil
}
