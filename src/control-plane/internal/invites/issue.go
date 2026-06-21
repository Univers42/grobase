/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   issue.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package invites

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// issue.go — invite issue / list / metadata. The cleartext token is returned ONCE at issue.

// IssueParams bundles the resolved invite target (scope + denormalized org for RLS/listing).
type IssueParams struct {
	ScopeKind string
	ScopeID   string
	OrgID     string // "" for a standalone scope
	Email     string
	Role      string
}

// Issue creates a pending invite for (scope, email, role), returning the cleartext token ONCE.
// A second pending invite for the same (scope, email) → ErrConflict (the partial unique index).
func (s *Service) Issue(ctx context.Context, p IssueParams, invitedBy string) (IssueInviteResponse, error) {
	if !validRoleForScope(p.ScopeKind, p.Role) {
		return IssueInviteResponse{}, ErrBadScope
	}
	cleartext, tokenHash, err := genToken()
	if err != nil {
		return IssueInviteResponse{}, err
	}
	var inv Invite
	row := s.db.AdminQueryRow(ctx, `
		INSERT INTO public.invites (scope_kind, scope_id, org_id, email, role, token_hash, invited_by, expires_at)
		VALUES ($1, $2::uuid, NULLIF($3,'')::uuid, $4, $5, $6, $7, now() + ($8 * interval '1 hour'))
		RETURNING id::text, scope_kind, scope_id::text, COALESCE(org_id::text,''), email, role, status,
		          invited_by, expires_at::text, created_at::text, accepted_by`,
		p.ScopeKind, p.ScopeID, p.OrgID, p.Email, p.Role, tokenHash, invitedBy, defaultInviteTTLHours)
	if err := scanInvite(row, &inv); err != nil {
		if pg.IsUniqueViolation(err) {
			return IssueInviteResponse{}, ErrConflict
		}
		return IssueInviteResponse{}, err
	}
	return IssueInviteResponse{Invite: inv, Token: cleartext}, nil
}

// List returns the pending invites for a scope (redacted — never the token).
func (s *Service) List(ctx context.Context, scopeKind, scopeID string) ([]Invite, error) {
	rows, err := s.db.AdminQuery(ctx, selectInvite+`
		 WHERE scope_kind=$1 AND scope_id::text=$2 AND status='pending'
		 ORDER BY created_at DESC`, scopeKind, scopeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Invite, 0)
	for rows.Next() {
		var inv Invite
		if err := scanInvite(rows, &inv); err != nil {
			return nil, err
		}
		out = append(out, inv)
	}
	return out, rows.Err()
}

// GetInvite returns one invite's redacted metadata by id (for the accept UI).
func (s *Service) GetInvite(ctx context.Context, inviteID string) (Invite, error) {
	var inv Invite
	row := s.db.AdminQueryRow(ctx, selectInvite+` WHERE id::text=$1`, inviteID)
	if err := scanInvite(row, &inv); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Invite{}, ErrNotFound
		}
		return Invite{}, err
	}
	return inv, nil
}
