package scim

import "context"

// service_mutations.go — the SCIM User replace/patch/delete lifecycle of
// *Service. Split out of service.go to keep each file at ≤5 funcs; behavior is
// byte-identical.

// ReplaceUser applies a SCIM PUT (full replace of mutable fields). active drives
// the soft-deactivate mirror onto org_members. Scoped to the token's tenant.
func (s *Service) ReplaceUser(ctx context.Context, b TokenBinding, scimID string, in SCIMUser) (SCIMUser, error) {
	rec, err := s.store.GetUser(ctx, b.TenantID, scimID)
	if err != nil {
		return SCIMUser{}, err
	}
	rec.UserName = in.UserName
	rec.DisplayName = in.displayName()
	rec.Emails = in.Emails
	rec.Active = in.Active
	if err := s.store.UpdateUser(ctx, rec); err != nil {
		return SCIMUser{}, err
	}
	if err := s.store.SetActive(ctx, rec, in.Active); err != nil {
		return SCIMUser{}, err
	}
	return s.GetUser(ctx, b, scimID)
}

// PatchUser applies a SCIM PATCH. The lifecycle signal SCIM provisioning needs is
// `replace active=false` (deactivate) / `active=true` (reactivate); other ops are
// accepted but ignored. Scoped to the token's tenant.
func (s *Service) PatchUser(ctx context.Context, b TokenBinding, scimID string, p PatchOp) (SCIMUser, error) {
	rec, err := s.store.GetUser(ctx, b.TenantID, scimID)
	if err != nil {
		return SCIMUser{}, err
	}
	if active, ok := patchedActive(p); ok {
		if err := s.store.SetActive(ctx, rec, active); err != nil {
			return SCIMUser{}, err
		}
	}
	return s.GetUser(ctx, b, scimID)
}

// DeleteUser deprovisions a SCIM User: it removes the org membership (reusing
// orgs.Service.RemoveMember) and deletes the SCIM mapping. Scoped to the token's
// tenant — a T2 token can never delete a T1 user (GetUser returns ErrNotFound).
// RemoveMember enforces orgs' own last-owner guard; a SCIM-provisioned member is
// never the last owner (role=developer), so this is safe, and a last-owner error
// is surfaced (the IdP should not deprovision the owner).
func (s *Service) DeleteUser(ctx context.Context, b TokenBinding, scimID string) error {
	rec, err := s.store.GetUser(ctx, b.TenantID, scimID)
	if err != nil {
		return err
	}
	if rec.OrgID != "" {
		if err := s.members.RemoveMember(ctx, rec.OrgID, rec.UserID); err != nil {
			return err
		}
	}
	return s.store.DeleteUser(ctx, b.TenantID, scimID)
}
