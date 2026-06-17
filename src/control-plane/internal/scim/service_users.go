package scim

import (
	"context"

	"github.com/google/uuid"
)

// service_users.go — the SCIM User create/read lifecycle of *Service. Split out
// of service.go to keep each file at ≤5 funcs; behavior is byte-identical.

// CreateUser provisions a SCIM User: it adds the org member (reusing
// orgs.Service.AddMember) and persists the SCIM mapping. The new resource's
// SCIM id is a freshly minted uuid. ErrNoOrg when the token has no org bound.
func (s *Service) CreateUser(ctx context.Context, b TokenBinding, in SCIMUser) (SCIMUser, error) {
	if b.OrgID == "" {
		return SCIMUser{}, ErrNoOrg
	}
	userID := in.resolveUserID()
	// Add (or upsert) the org membership — the EXISTING membership API.
	if err := s.members.AddMember(ctx, b.OrgID, userID, defaultMemberRole, "scim"); err != nil {
		return SCIMUser{}, err
	}
	rec := newUserRecord(b, in, userID)
	if err := s.store.InsertUser(ctx, rec); err != nil {
		return SCIMUser{}, err
	}
	got, err := s.store.GetUser(ctx, b.TenantID, rec.SCIMID)
	if err != nil {
		return SCIMUser{}, err
	}
	return got.toSCIM(), nil
}

// newUserRecord assembles the persisted mapping for a freshly provisioned SCIM
// User: a freshly minted SCIM id, the wall-binding tenant/org, and active=true.
func newUserRecord(b TokenBinding, in SCIMUser, userID string) userRecord {
	return userRecord{
		SCIMID:      uuid.NewString(),
		TenantID:    b.TenantID,
		OrgID:       b.OrgID,
		UserName:    in.UserName,
		UserID:      userID,
		DisplayName: in.displayName(),
		Emails:      in.Emails,
		Active:      true, // a newly provisioned user is active
	}
}

// GetUser fetches one SCIM User by id, scoped to the token's tenant (the wall).
func (s *Service) GetUser(ctx context.Context, b TokenBinding, scimID string) (SCIMUser, error) {
	rec, err := s.store.GetUser(ctx, b.TenantID, scimID)
	if err != nil {
		return SCIMUser{}, err
	}
	return rec.toSCIM(), nil
}

// FindByUserName resolves a SCIM User by userName, scoped to the token's tenant.
func (s *Service) FindByUserName(ctx context.Context, b TokenBinding, userName string) (SCIMUser, bool, error) {
	rec, err := s.store.FindByUserName(ctx, b.TenantID, userName)
	if err == ErrNotFound {
		return SCIMUser{}, false, nil
	}
	if err != nil {
		return SCIMUser{}, false, err
	}
	return rec.toSCIM(), true, nil
}
