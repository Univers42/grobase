package orgs

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
)

// invite_accept.go — single-use invite acceptance (resolve by hash -> atomic claim
// -> join the org), all within one transaction.

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

	inviteID, orgID, role, err := resolveAcceptableInvite(ctx, tx, tokenHash)
	if err != nil {
		return Org{}, "", err
	}
	if err := claimInviteAndJoin(ctx, tx, inviteClaim{inviteID: inviteID, orgID: orgID, role: role, acceptedBy: acceptedBy}); err != nil {
		return Org{}, "", err
	}
	o, err := readOrgAndCommit(ctx, tx, orgID)
	if err != nil {
		return Org{}, "", err
	}
	return o, role, nil
}

// readOrgAndCommit reads the org back (for the accept response) within tx then
// commits — the final step shared by the AcceptInvite success path.
func readOrgAndCommit(ctx context.Context, tx pgx.Tx, orgID string) (Org, error) {
	var o Org
	orgRow := tx.QueryRow(ctx, selectOrg+` WHERE id::text=$1`, orgID)
	if err := scanOrg(orgRow, &o); err != nil {
		return Org{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Org{}, err
	}
	return o, nil
}

// resolveAcceptableInvite looks up the invite by token hash and validates it is
// pending + unexpired. A missing row -> ErrInviteInvalid; non-pending ->
// ErrInviteConsumed; expired -> ErrInviteExpired (and it best-effort marks the row
// expired within tx so a re-presentation is consistently 410).
func resolveAcceptableInvite(ctx context.Context, tx pgx.Tx, tokenHash string) (inviteID, orgID, role string, err error) {
	var (
		status  string
		expired bool
	)
	row := tx.QueryRow(ctx, `
		SELECT id::text, org_id::text, role, status,
		       coalesce(expires_at < now(), false) AS expired
		  FROM public.org_invites WHERE token_hash=$1`, tokenHash)
	if err = row.Scan(&inviteID, &orgID, &role, &status, &expired); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", "", "", ErrInviteInvalid
		}
		return "", "", "", err
	}
	if status != "pending" {
		return "", "", "", ErrInviteConsumed
	}
	if expired {
		_, _ = tx.Exec(ctx, `UPDATE public.org_invites SET status='expired' WHERE id::text=$1`, inviteID)
		_ = tx.Commit(ctx)
		return "", "", "", ErrInviteExpired
	}
	return inviteID, orgID, role, nil
}

// inviteClaim bundles the resolved invite (inviteID/orgID/role) and the accepting
// user (acceptedBy) for claimInviteAndJoin.
type inviteClaim struct {
	inviteID   string
	orgID      string
	role       string
	acceptedBy string
}

// claimInviteAndJoin performs the atomic single-use claim (flip pending->accepted,
// ErrInviteConsumed if a concurrent acceptance won the race) then adds the
// accepting user to the org with the invited role — both within tx.
func claimInviteAndJoin(ctx context.Context, tx pgx.Tx, c inviteClaim) error {
	tag, err := tx.Exec(ctx, `
		UPDATE public.org_invites
		   SET status='accepted', accepted_by=$2, accepted_at=now()
		 WHERE id::text=$1 AND status='pending'`, c.inviteID, c.acceptedBy)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrInviteConsumed
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO public.org_members (org_id, user_id, role, invited_by)
		VALUES ($1::uuid, $2, $3, NULL)
		ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
		c.orgID, c.acceptedBy, c.role)
	return err
}
