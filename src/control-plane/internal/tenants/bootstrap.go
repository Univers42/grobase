package tenants

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/jackc/pgx/v5"
)

// Bootstrap creates a tenant + default ABAC role + first API key in one shot.
//
// The ABAC seeding speaks SQL directly into the same Postgres because
// permission-engine lives in the same DB; cross-service call would be
// transactional gymnastics. If you swap permission-engine to an external
// store, swap this for an HTTP call to it.
func (s *Service) Bootstrap(ctx context.Context, id, name string, req BootstrapRequest) (BootstrapResponse, error) {
	// Self-serve bootstrap has no plan selection — defaults to free ("").
	tenant, created, err := s.findOrCreateBySlug(ctx, id, name, req.OwnerUserID, "")
	if err != nil {
		return BootstrapResponse{}, err
	}

	roles := []string{}
	if req.SeedRoles {
		assigned, rerr := s.seedDefaultRole(ctx, id, req.OwnerUserID, req.DefaultRoleName)
		if rerr != nil {
			s.log.Warn("seed default role failed", "tenant", id, "err", rerr)
		} else if assigned != "" {
			roles = append(roles, assigned)
		}
	}

	keyName := strings.TrimSpace(req.DefaultKeyName)
	if keyName == "" {
		keyName = "default"
	}

	// Idempotent key issuance: reuse an existing active key with this name
	// rather than re-minting a secret (which would invalidate live clients).
	// Mirrors BootstrapForUser so both bootstrap paths behave identically.
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

	// If an active key with the requested name already exists, return the
	// tenant alone — we will not surface a usable secret a second time.
	existingKey, err := s.findActiveKeyByName(ctx, tenant.ID, defaultKeyName)
	if err != nil {
		return SelfBootstrapResult{}, err
	}
	if existingKey != nil {
		return SelfBootstrapResult{
			Tenant:   tenant,
			Created:  created,
			KeyReuse: true,
		}, nil
	}

	key, err := s.IssueKey(ctx, tenant.ID, IssueKeyRequest{
		Name:   defaultKeyName,
		Scopes: []string{"read", "write", "admin"},
	})
	if err != nil {
		return SelfBootstrapResult{}, fmt.Errorf("issue first key: %w", err)
	}
	return SelfBootstrapResult{
		Tenant:  tenant,
		APIKey:  &key,
		Created: created,
	}, nil
}

// findForUser resolves the tenant owned by userID WITHOUT creating one. It
// returns ErrNotFound when the user owns no tenant yet — tenant creation is the
// explicit job of POST /v1/tenants/me/bootstrap, never a side effect of a /me
// read. (Self-serve reads use this; the bootstrap path keeps findOrCreateForUser.)
func (s *Service) findForUser(ctx context.Context, userID string) (Tenant, error) {
	row, err := s.queryOne(ctx, selectTenant+` WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return Tenant{}, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Tenant{}, ErrNotFound
		}
		return Tenant{}, err
	}
	return t, nil
}

func (s *Service) findOrCreateForUser(ctx context.Context, userID, email string) (Tenant, bool, error) {
	row, err := s.queryOne(ctx, selectTenant+` WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return Tenant{}, false, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err == nil {
		return t, false, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return Tenant{}, false, err
	}

	// Defensive: trigger failed or backfill missed this user. Create now.
	slug := slugFromUserUUID(userID)
	name := email
	if name == "" {
		name = slug
	}
	created, err := s.Create(ctx, CreateTenantRequest{
		ID:          slug,
		Name:        name,
		OwnerUserID: userID,
	})
	if errors.Is(err, ErrConflict) {
		// Race: another caller (or the trigger) inserted it between our
		// SELECT and our INSERT. Re-fetch.
		row2, err2 := s.queryOne(ctx, selectTenant+` WHERE slug = $1`, slug)
		if err2 != nil {
			return Tenant{}, false, err2
		}
		if err2 := scanTenant(row2, &t); err2 != nil {
			return Tenant{}, false, err2
		}
		return t, false, nil
	}
	if err != nil {
		return Tenant{}, false, err
	}
	return created, true, nil
}

func (s *Service) findActiveKeyByName(ctx context.Context, tenantSlug, keyName string) (*APIKey, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT k.id::text, $1::text, k.name, k.key_prefix, k.scopes,
		       k.created_at::text, k.expires_at::text,
		       k.last_used_at::text, k.revoked_at::text
		  FROM public.tenant_api_keys k
		  JOIN public.tenants t ON t.id = k.tenant_id
		 WHERE t.slug = $1 AND k.name = $2 AND k.revoked_at IS NULL
		 LIMIT 1`, tenantSlug, keyName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, nil
	}
	var k APIKey
	if err := rows.Scan(&k.ID, &k.TenantID, &k.Name, &k.KeyPrefix,
		&k.Scopes, &k.CreatedAt, &k.ExpiresAt, &k.LastUsedAt, &k.RevokedAt); err != nil {
		return nil, err
	}
	return &k, nil
}

// slugFromUserUUID mirrors the SQL trigger so Go and PG generate the same slug.
func slugFromUserUUID(userUUID string) string {
	out := make([]rune, 0, 2+len(userUUID))
	out = append(out, 't', '-')
	for _, r := range userUUID {
		if r == '-' {
			continue
		}
		out = append(out, r)
	}
	return string(out)
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
	if !uuidRe.MatchString(ownerUserID) {
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
	for _, p := range spec.Policies {
		if _, perr := s.perm.EnsurePolicy(ctx, roleID, p); perr != nil {
			return "", perr
		}
	}
	namespaced := provision.NamespacedRoleName(provision.RoleKey(slug, spec.Name))
	if err := s.perm.AssignRole(ctx, ownerUserID, namespaced); err != nil {
		return "", err
	}
	return namespaced, nil
}
