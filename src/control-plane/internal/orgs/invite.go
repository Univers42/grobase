package orgs

import (
	"context"
	"errors"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// invite.go — email invite issue/list/revoke (sha256-HASHED token). The token
// crypto lives in invite_token.go; acceptance lives in invite_accept.go.
//
// SECURITY DISCIPLINE (kernel rule #7 / D-026): the invite token is high-entropy
// (32 bytes from crypto/rand = 256 bits). We store ONLY lower-hex sha256(token);
// the cleartext is returned ONCE at issue time (to be emailed) and NEVER
// persisted. Acceptance recomputes sha256(presented_token) and does an indexed
// equality lookup against token_hash — a fast hash is correct for a high-entropy
// secret (there is nothing to brute-force), exactly as tenant_api_keys does for
// its 160-bit key payload. No password-hash here by design.

const (
	// inviteTokenBytes is the raw entropy of an invite token (256 bits).
	inviteTokenBytes = 32
	// inviteTokenPrefix tags the cleartext so a human / log can recognise it; it
	// is NOT part of the hashed material discipline (the whole token is hashed).
	inviteTokenPrefix = "mbi_"
	// defaultInviteTTLHours is how long an invite stays acceptable.
	defaultInviteTTLHours = 168 // 7 days
)

// IssueInvite creates a pending invite for (org,email,role), returning the
// cleartext token ONCE. invitedBy is the GoTrue user uuid of the inviter.
func (s *Service) IssueInvite(ctx context.Context, orgID, email, role, invitedBy string) (IssueInviteResponse, error) {
	role = strings.TrimSpace(role)
	if role == "" {
		role = string(RoleViewer)
	}
	if !validRole(role) {
		return IssueInviteResponse{}, errors.New("invalid role")
	}
	cleartext, tokenHash, err := generateInviteToken()
	if err != nil {
		return IssueInviteResponse{}, err
	}
	inv, err := s.insertInvite(ctx, orgID, email, role, tokenHash, invitedBy)
	if err != nil {
		return IssueInviteResponse{}, err
	}
	return IssueInviteResponse{Invite: inv, Token: cleartext}, nil
}

// insertInvite writes the pending invite row and scans the redacted projection
// back, mapping a uniqueness violation (an outstanding invite for the same
// (org,email)) to ErrConflict.
func (s *Service) insertInvite(ctx context.Context, orgID, email, role, tokenHash, invitedBy string) (Invite, error) {
	rows, err := s.db.AdminQuery(ctx, `
		INSERT INTO public.org_invites (org_id, email, role, token_hash, invited_by, expires_at)
		VALUES ($1::uuid, $2, $3, $4, $5, now() + ($6 * interval '1 hour'))
		RETURNING id::text, org_id::text, email, role, status, invited_by,
		          expires_at::text, created_at::text, accepted_by`,
		orgID, email, role, tokenHash, invitedBy, defaultInviteTTLHours)
	if err != nil {
		if pg.IsUniqueViolation(err) {
			return Invite{}, ErrConflict
		}
		return Invite{}, err
	}
	var inv Invite
	if err := scanInvite(&singleRow{rows: rows}, &inv); err != nil {
		if pg.IsUniqueViolation(err) {
			return Invite{}, ErrConflict
		}
		return Invite{}, err
	}
	return inv, nil
}

// ListInvites returns the org's pending invites (redacted — never the token).
func (s *Service) ListInvites(ctx context.Context, orgID string) ([]Invite, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT id::text, org_id::text, email, role, status, invited_by,
		       expires_at::text, created_at::text, accepted_by
		  FROM public.org_invites
		 WHERE org_id::text=$1 AND status='pending'
		 ORDER BY created_at DESC`, orgID)
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

// RevokeInvite flips a pending invite to status='revoked' (keyed by org + invite
// id, so a caller can never revoke another org's invite).
func (s *Service) RevokeInvite(ctx context.Context, orgID, inviteID string) error {
	tag, err := s.exec(ctx, `
		UPDATE public.org_invites SET status='revoked'
		 WHERE id::text=$1 AND org_id::text=$2 AND status='pending'`, inviteID, orgID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
