package orgs

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// invite.go — email invite issue (sha256-HASHED token) -> accept.
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

// generateInviteToken returns (cleartext, lower-hex sha256(cleartext)).
func generateInviteToken() (cleartext, tokenHash string, err error) {
	raw := make([]byte, inviteTokenBytes)
	if _, err = rand.Read(raw); err != nil {
		return "", "", err
	}
	cleartext = inviteTokenPrefix + hex.EncodeToString(raw)
	tokenHash = hashInviteToken(cleartext)
	return cleartext, tokenHash, nil
}

// hashInviteToken computes lower-hex sha256(token) — the SAME transformation the
// gate independently checks via `printf %s "$token" | sha256sum`.
func hashInviteToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

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
	rows, err := s.db.AdminQuery(ctx, `
		INSERT INTO public.org_invites (org_id, email, role, token_hash, invited_by, expires_at)
		VALUES ($1::uuid, $2, $3, $4, $5, now() + ($6 * interval '1 hour'))
		RETURNING id::text, org_id::text, email, role, status, invited_by,
		          expires_at::text, created_at::text, accepted_by`,
		orgID, email, role, tokenHash, invitedBy, defaultInviteTTLHours)
	if err != nil {
		if shared.IsUniqueViolation(err) {
			return IssueInviteResponse{}, ErrConflict
		}
		return IssueInviteResponse{}, err
	}
	var inv Invite
	if err := scanInvite(&singleRow{rows: rows}, &inv); err != nil {
		if shared.IsUniqueViolation(err) {
			return IssueInviteResponse{}, ErrConflict
		}
		return IssueInviteResponse{}, err
	}
	return IssueInviteResponse{Invite: inv, Token: cleartext}, nil
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

// AcceptInvite consumes a cleartext invite token: it resolves the invite by
// sha256(token), validates it is pending + unexpired, adds the accepting user to
// the org with the invited role, and flips the invite to accepted — all in ONE
// transaction so a token is single-use (the conditional UPDATE that flips
// status='pending' -> 'accepted' is the atomic claim). acceptedBy is the GoTrue
// user uuid of the accepting caller.
//
// Failure modes (each a distinct sentinel the handler maps to a specific status):
//   - no matching hash            -> ErrInviteInvalid  (401)
//   - present but expired         -> ErrInviteExpired  (410)
//   - already accepted/revoked    -> ErrInviteConsumed (409)
func (s *Service) AcceptInvite(ctx context.Context, token, acceptedBy string) (Org, string, error) {
	tokenHash := hashInviteToken(strings.TrimSpace(token))

	conn, err := s.db.AcquireConn(ctx)
	if err != nil {
		return Org{}, "", err
	}
	defer conn.Release()
	tx, err := conn.Begin(ctx)
	if err != nil {
		return Org{}, "", err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Resolve the invite by hash. Existence is the first wall; status/expiry are
	// the second. A wrong/replayed-but-never-issued token has no row at all.
	var (
		inviteID, orgID, role, status string
		expired                       bool
	)
	row := tx.QueryRow(ctx, `
		SELECT id::text, org_id::text, role, status,
		       coalesce(expires_at < now(), false) AS expired
		  FROM public.org_invites WHERE token_hash=$1`, tokenHash)
	if err := row.Scan(&inviteID, &orgID, &role, &status, &expired); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Org{}, "", ErrInviteInvalid
		}
		return Org{}, "", err
	}
	if status != "pending" {
		return Org{}, "", ErrInviteConsumed
	}
	if expired {
		// Best-effort mark expired so a re-presentation is consistently 410.
		_, _ = tx.Exec(ctx, `UPDATE public.org_invites SET status='expired' WHERE id::text=$1`, inviteID)
		_ = tx.Commit(ctx)
		return Org{}, "", ErrInviteExpired
	}

	// Atomic single-use claim: only flip if STILL pending. RowsAffected==0 means a
	// concurrent acceptance won the race -> consumed.
	tag, err := tx.Exec(ctx, `
		UPDATE public.org_invites
		   SET status='accepted', accepted_by=$2, accepted_at=now()
		 WHERE id::text=$1 AND status='pending'`, inviteID, acceptedBy)
	if err != nil {
		return Org{}, "", err
	}
	if tag.RowsAffected() == 0 {
		return Org{}, "", ErrInviteConsumed
	}

	// Add the accepting user as a member with the invited role.
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.org_members (org_id, user_id, role, invited_by)
		VALUES ($1::uuid, $2, $3, NULL)
		ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
		orgID, acceptedBy, role); err != nil {
		return Org{}, "", err
	}

	// Read back the org (for the response) within the same tx.
	var o Org
	orgRow := tx.QueryRow(ctx, selectOrg+` WHERE id::text=$1`, orgID)
	if err := scanOrg(orgRow, &o); err != nil {
		return Org{}, "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return Org{}, "", err
	}
	return o, role, nil
}

func scanInvite(row interface{ Scan(...any) error }, inv *Invite) error {
	return row.Scan(&inv.ID, &inv.OrgID, &inv.Email, &inv.Role, &inv.Status,
		&inv.InvitedBy, &inv.ExpiresAt, &inv.CreatedAt, &inv.AcceptedBy)
}
