package scim

import (
	"context"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/google/uuid"
)

// memberProvisioner is the seam onto internal/orgs membership lifecycle. SCIM
// provisioning REUSES the existing org membership API — it never reinvents
// membership. *orgs.Service satisfies it; a fake satisfies it in unit tests.
// AddMember(orgID, userID, role, invitedBy) upserts; RemoveMember(orgID, userID)
// deletes. The soft-deactivate (active:false) is a column flip handled by the
// store (org_members.active), NOT a membership add/remove.
type memberProvisioner interface {
	AddMember(ctx context.Context, orgID, userID, role, invitedBy string) error
	RemoveMember(ctx context.Context, orgID, userID string) error
}

// Service drives the SCIM User lifecycle: it binds a bearer token to a tenant
// (+org), maps SCIM Users onto org members via the existing memberProvisioner,
// and persists the SCIM resource mapping (scim_users). It is the layer the HTTP
// handler calls; the store owns SQL, orgs owns membership.
type Service struct {
	store   *store
	members memberProvisioner
	log     *slog.Logger
}

// NewService wires the DB-backed store + the org membership provisioner + logger.
func NewService(db *shared.Postgres, members memberProvisioner, log *slog.Logger) *Service {
	return &Service{store: newStore(db), members: members, log: log}
}

// Authorize resolves a cleartext SCIM bearer to its tenant/org binding and stamps
// last_used_at. ErrTokenInvalid for a missing/unknown/revoked token (the wall).
func (s *Service) Authorize(ctx context.Context, bearer string) (TokenBinding, error) {
	b, err := s.store.VerifyToken(ctx, bearer)
	if err != nil {
		return TokenBinding{}, err
	}
	s.store.Touch(ctx, b.TokenID)
	return b, nil
}

// IssueToken creates a SCIM bearer for (tenantID, orgID) and returns the
// cleartext ONCE. Admin-only (service token) at the handler layer.
func (s *Service) IssueToken(ctx context.Context, tenantID, orgID, description string) (cleartext, tokenID string, err error) {
	return s.store.IssueToken(ctx, tenantID, orgID, description)
}

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
	rec := userRecord{
		SCIMID:      uuid.NewString(),
		TenantID:    b.TenantID,
		OrgID:       b.OrgID,
		UserName:    in.UserName,
		UserID:      userID,
		DisplayName: in.displayName(),
		Emails:      in.Emails,
		Active:      true, // a newly provisioned user is active
	}
	if err := s.store.InsertUser(ctx, rec); err != nil {
		return SCIMUser{}, err
	}
	got, err := s.store.GetUser(ctx, b.TenantID, rec.SCIMID)
	if err != nil {
		return SCIMUser{}, err
	}
	return got.toSCIM(), nil
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
	// Mirror the active flag onto the org membership (the deactivate signal).
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
func (s *Service) DeleteUser(ctx context.Context, b TokenBinding, scimID string) error {
	rec, err := s.store.GetUser(ctx, b.TenantID, scimID)
	if err != nil {
		return err
	}
	if rec.OrgID != "" {
		// RemoveMember enforces orgs' own last-owner guard; a SCIM-provisioned
		// member is never the last owner (role=developer), so this is safe. A
		// last-owner error is surfaced (the IdP should not deprovision the owner).
		if err := s.members.RemoveMember(ctx, rec.OrgID, rec.UserID); err != nil {
			return err
		}
	}
	return s.store.DeleteUser(ctx, b.TenantID, scimID)
}

// RevokeToken revokes a SCIM bearer (admin path). Scoped to the tenant.
func (s *Service) RevokeToken(ctx context.Context, tenantID, tokenID string) error {
	return s.store.Revoke(ctx, tenantID, tokenID)
}
