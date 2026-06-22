/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   accept.go                                          :+:      :+:    :+:   */
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
	"strings"

	"github.com/jackc/pgx/v5"
)

// accept.go — single-use invite acceptance (registered caller): resolve by token hash →
// atomic claim (pending→accepted) → scope-dispatch join → commit, all in ONE transaction.

// Accept consumes a cleartext token for an already-registered caller (acceptedBy = the
// caller's GoTrue subject), joining them to the invited scope with the invited role.
func (s *Service) Accept(ctx context.Context, token, acceptedBy string) (Invite, error) {
	conn, err := s.db.AcquireConn(ctx)
	if err != nil {
		return Invite{}, err
	}
	defer conn.Release()
	tx, err := conn.Begin(ctx)
	if err != nil {
		return Invite{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	inv, fatal, err := resolveInvite(ctx, tx, hashToken(strings.TrimSpace(token)))
	if err != nil {
		return Invite{}, err
	}
	if fatal != nil { // expired: row marked + tx committed inside resolveInvite
		return Invite{}, fatal
	}
	if err := claimAndJoin(ctx, tx, inv, acceptedBy); err != nil {
		return Invite{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Invite{}, err
	}
	inv.Status, inv.AcceptedBy = "accepted", &acceptedBy
	return inv, nil
}

// resolveInvite looks up the invite by token hash and validates pending + unexpired. A missing
// row → ErrInvalid; non-pending → ErrConsumed; expired → (marks expired, commits) ErrExpired
// returned as `fatal` so the caller stops without rolling back the expiry mark.
func resolveInvite(ctx context.Context, tx pgx.Tx, tokenHash string) (inv Invite, fatal, err error) {
	var expired bool
	row := tx.QueryRow(ctx, `
		SELECT id::text, scope_kind, scope_id::text, COALESCE(org_id::text,''), email, role, status,
		       invited_by, expires_at::text, created_at::text, accepted_by,
		       coalesce(expires_at < now(), false)
		  FROM public.invites WHERE token_hash=$1`, tokenHash)
	if err = row.Scan(&inv.ID, &inv.ScopeKind, &inv.ScopeID, &inv.OrgID, &inv.Email, &inv.Role,
		&inv.Status, &inv.InvitedBy, &inv.ExpiresAt, &inv.CreatedAt, &inv.AcceptedBy, &expired); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Invite{}, nil, ErrInvalid
		}
		return Invite{}, nil, err
	}
	if inv.Status != "pending" {
		return Invite{}, nil, ErrConsumed
	}
	if expired {
		_, _ = tx.Exec(ctx, `UPDATE public.invites SET status='expired' WHERE id::text=$1`, inv.ID)
		_ = tx.Commit(ctx)
		return Invite{}, ErrExpired, nil
	}
	return inv, nil, nil
}

// claimAndJoin performs the atomic single-use claim (pending→accepted; ErrConsumed if a
// concurrent acceptance won) then inserts the scope membership/grant for the invited scope.
func claimAndJoin(ctx context.Context, tx pgx.Tx, inv Invite, acceptedBy string) error {
	tag, err := tx.Exec(ctx, `
		UPDATE public.invites SET status='accepted', accepted_by=$2, accepted_at=now()
		 WHERE id::text=$1 AND status='pending'`, inv.ID, acceptedBy)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrConsumed
	}
	return joinScope(ctx, tx, inv, acceptedBy)
}
