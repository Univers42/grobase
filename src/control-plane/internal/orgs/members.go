package orgs

import "context"

// members.go — org membership + role lookup, guarded by the last-owner invariant.

// MemberRole resolves the caller's role within an org. ok=false means the user is
// NOT a member (the cross-org isolation primitive: a non-member can never see or
// act on an org). This is the function the capability gate calls.
func (s *Service) MemberRole(ctx context.Context, orgID, userID string) (Role, bool) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT role FROM public.org_members WHERE org_id::text=$1 AND user_id=$2`, orgID, userID)
	if err != nil {
		return "", false
	}
	defer rows.Close()
	if !rows.Next() {
		return "", false
	}
	var role string
	if err := rows.Scan(&role); err != nil {
		return "", false
	}
	return Role(role), true
}

// ListMembers returns the org's membership.
func (s *Service) ListMembers(ctx context.Context, orgID string) ([]Member, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT org_id::text, user_id, role, invited_by, created_at::text
		  FROM public.org_members WHERE org_id::text=$1 ORDER BY created_at`, orgID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Member, 0)
	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.OrgID, &m.UserID, &m.Role, &m.InvitedBy, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// AddMember upserts a (org,user)->role membership. Used by invite acceptance.
func (s *Service) AddMember(ctx context.Context, orgID, userID, role, invitedBy string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.org_members (org_id, user_id, role, invited_by)
		VALUES ($1::uuid, $2, $3, NULLIF($4,''))
		ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
		orgID, userID, role, invitedBy)
}

// SetMemberRole changes a member's role, guarded by the last-owner invariant: it
// refuses to demote the SOLE owner (ErrLastOwner). The admin-vs-owner asymmetry
// is enforced in the handler (canSetRole) before this is called.
func (s *Service) SetMemberRole(ctx context.Context, orgID, userID, newRole string) error {
	if newRole != string(RoleOwner) {
		// Demoting away from owner: block if this is the last owner.
		isOwner, owners, err := s.ownerCount(ctx, orgID, userID)
		if err != nil {
			return err
		}
		if isOwner && owners <= 1 {
			return ErrLastOwner
		}
	}
	tag, err := s.exec(ctx,
		`UPDATE public.org_members SET role=$3 WHERE org_id::text=$1 AND user_id=$2`,
		orgID, userID, newRole)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// RemoveMember deletes a membership, guarded by the last-owner invariant: it
// refuses to remove the SOLE owner (ErrLastOwner) so an org always retains a
// break-glass owner.
func (s *Service) RemoveMember(ctx context.Context, orgID, userID string) error {
	isOwner, owners, err := s.ownerCount(ctx, orgID, userID)
	if err != nil {
		return err
	}
	if isOwner && owners <= 1 {
		return ErrLastOwner
	}
	tag, err := s.exec(ctx,
		`DELETE FROM public.org_members WHERE org_id::text=$1 AND user_id=$2`, orgID, userID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
