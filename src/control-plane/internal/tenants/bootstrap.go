package tenants

import (
	"context"
	"errors"
	"fmt"
)

// Bootstrap creates a tenant + default ABAC role + first API key in one shot.
//
// Self-serve bootstrap has no plan selection, so the tenant defaults to free
// (""). Key issuance is idempotent: it reuses an existing active key of the
// same name rather than re-minting a secret (which would invalidate live
// clients), mirroring BootstrapForUser so both bootstrap paths behave
// identically.
//
// The ABAC seeding speaks SQL directly into the same Postgres because
// permission-engine lives in the same DB; cross-service call would be
// transactional gymnastics. If you swap permission-engine to an external
// store, swap this for an HTTP call to it.
func (s *Service) Bootstrap(ctx context.Context, id, name string, req BootstrapRequest) (BootstrapResponse, error) {
	tenant, created, err := s.findOrCreateBySlug(ctx, id, name, req.OwnerUserID, "")
	if err != nil {
		return BootstrapResponse{}, err
	}
	roles := s.seedBootstrapRoles(ctx, id, req)
	keyName := defaultKeyName(req.DefaultKeyName)

	existing, err := s.findActiveKeyByName(ctx, id, keyName)
	if err != nil {
		return BootstrapResponse{}, err
	}
	if existing != nil {
		return BootstrapResponse{Tenant: tenant, Roles: roles, Created: created, KeyReuse: true}, nil
	}
	key, err := s.IssueKey(ctx, id, IssueKeyRequest{Name: keyName, Scopes: []string{"read", "write", "admin"}})
	if err != nil {
		return BootstrapResponse{}, fmt.Errorf("issue first key: %w", err)
	}
	return BootstrapResponse{Tenant: tenant, APIKey: &key, Roles: roles, Created: created}, nil
}

// seedBootstrapRoles seeds the default ABAC role when requested, logging (not
// failing) on error — mirrors the original inline behavior.
func (s *Service) seedBootstrapRoles(ctx context.Context, id string, req BootstrapRequest) []string {
	roles := []string{}
	if !req.SeedRoles {
		return roles
	}
	assigned, rerr := s.seedDefaultRole(ctx, id, req.OwnerUserID, req.DefaultRoleName)
	if rerr != nil {
		s.log.Warn("seed default role failed", "tenant", id, "err", rerr)
	} else if assigned != "" {
		roles = append(roles, assigned)
	}
	return roles
}

// findOrCreateBySlug creates the tenant or returns the existing one. The second
// return reports whether it was created this call. Idempotent — relies on
// Create mapping a 23505 to ErrConflict (see isUniqueViolation).
func (s *Service) findOrCreateBySlug(ctx context.Context, id, name, ownerUserID, plan string) (Tenant, bool, error) {
	t, err := s.Create(ctx, CreateTenantRequest{ID: id, Name: name, OwnerUserID: ownerUserID, Plan: plan})
	if err == nil {
		return t, true, nil
	}
	if !errors.Is(err, ErrConflict) {
		return Tenant{}, false, err
	}
	t, err = s.FindOne(ctx, id)
	if err != nil {
		return Tenant{}, false, err
	}
	return t, false, nil
}

// SelfBootstrapResult is the response shape for the JWT-authenticated bootstrap.
type SelfBootstrapResult struct {
	Tenant   Tenant            `json:"tenant"`
	APIKey   *IssueKeyResponse `json:"api_key,omitempty"`
	Created  bool              `json:"created"`
	KeyReuse bool              `json:"key_reuse,omitempty"`
}

// BootstrapForUser is the authenticated-by-JWT counterpart to Bootstrap.
//
// The GoTrue post-signup trigger (migration 033) is expected to have created
// the tenant row already. This method:
//  1. Looks up the existing tenant by owner_user_id.
//  2. Defensive UPSERT if the trigger failed for any reason (auto-recovery).
//  3. Issues a "default" API key if the tenant doesn't already have an
//     active one with that name. Otherwise returns just the tenant — we
//     never re-mint a key for an existing one (would invalidate clients).
func (s *Service) BootstrapForUser(ctx context.Context, userID, email, defaultKeyName string) (SelfBootstrapResult, error) {
	if userID == "" {
		return SelfBootstrapResult{}, fmt.Errorf("user_id is required")
	}
	if defaultKeyName == "" {
		defaultKeyName = "default"
	}
	tenant, created, err := s.findOrCreateForUser(ctx, userID, email)
	if err != nil {
		return SelfBootstrapResult{}, err
	}
	return s.selfKeyResult(ctx, tenant, defaultKeyName, created)
}

// selfKeyResult reuses an existing active key (surfacing key_reuse, never a
// second secret) or issues a first one for the resolved tenant.
func (s *Service) selfKeyResult(ctx context.Context, tenant Tenant, keyName string, created bool) (SelfBootstrapResult, error) {
	existingKey, err := s.findActiveKeyByName(ctx, tenant.ID, keyName)
	if err != nil {
		return SelfBootstrapResult{}, err
	}
	if existingKey != nil {
		return SelfBootstrapResult{Tenant: tenant, Created: created, KeyReuse: true}, nil
	}
	key, err := s.IssueKey(ctx, tenant.ID, IssueKeyRequest{
		Name:   keyName,
		Scopes: []string{"read", "write", "admin"},
	})
	if err != nil {
		return SelfBootstrapResult{}, fmt.Errorf("issue first key: %w", err)
	}
	return SelfBootstrapResult{Tenant: tenant, APIKey: &key, Created: created}, nil
}
