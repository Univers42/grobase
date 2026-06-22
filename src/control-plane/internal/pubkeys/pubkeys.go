/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   pubkeys.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 07:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 07:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pubkeys

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// pubkeys.go — the registry + fulfilment operations, all over the admin pool.

const selectPubkey = `
  SELECT user_id, org_id::text, ed25519_pub, x25519_pub, v42_address, pubkey_sig,
         created_at::text, COALESCE(rotated_at::text,'')
    FROM public.user_pubkeys`

// Register upserts the caller's (user, org) public keys (a re-register rotates them).
func (s *Service) Register(ctx context.Context, orgID, userID string, req RegisterPubkeyRequest) (Pubkey, error) {
	var p Pubkey
	row := s.db.AdminQueryRow(ctx, `
		INSERT INTO public.user_pubkeys (user_id, org_id, ed25519_pub, x25519_pub, v42_address, pubkey_sig)
		VALUES ($1, $2::uuid, $3, $4, $5, $6)
		ON CONFLICT (user_id, org_id) DO UPDATE SET ed25519_pub = EXCLUDED.ed25519_pub,
		  x25519_pub = EXCLUDED.x25519_pub, v42_address = EXCLUDED.v42_address,
		  pubkey_sig = EXCLUDED.pubkey_sig, rotated_at = now()
		RETURNING user_id, org_id::text, ed25519_pub, x25519_pub, v42_address, pubkey_sig,
		          created_at::text, COALESCE(rotated_at::text,'')`,
		userID, orgID, req.Ed25519Pub, req.X25519Pub, req.V42Address, req.PubkeySig)
	if err := scanPubkey(row, &p); err != nil {
		return Pubkey{}, err
	}
	return p, nil
}

// Get reads one member's pubkey within an org (ErrNotFound when absent).
func (s *Service) Get(ctx context.Context, orgID, userID string) (Pubkey, error) {
	var p Pubkey
	row := s.db.AdminQueryRow(ctx, selectPubkey+` WHERE user_id=$1 AND org_id=$2::uuid`, userID, orgID)
	if err := scanPubkey(row, &p); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Pubkey{}, ErrNotFound
		}
		return Pubkey{}, err
	}
	return p, nil
}

// RecordWrap records that a grant's scope key has been wrapped to a member (idempotent). The
// grant must live in orgID (so a caller cannot mark a wrap on another org's grant).
func (s *Service) RecordWrap(ctx context.Context, orgID, grantID, userID string) error {
	var gid string
	row := s.db.AdminQueryRow(ctx,
		`SELECT id::text FROM public.project_grants WHERE id::text=$1 AND org_id::text=$2`, grantID, orgID)
	if err := row.Scan(&gid); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	return s.db.AdminExec(ctx, `
		INSERT INTO public.grant_key_wraps (grant_id, user_id) VALUES ($1::uuid, $2)
		ON CONFLICT (grant_id, user_id) DO NOTHING`, grantID, userID)
}

// Fulfilled reports whether the grant's scope key is wrapped to EVERY effective member of the
// grant (a user grant = that user; a team/group grant = its members), listing the missing.
func (s *Service) Fulfilled(ctx context.Context, grantID string) (FulfilledResponse, error) {
	rows, err := s.db.AdminQuery(ctx, `
		WITH members AS (
		  SELECT g.grantee_id AS user_id FROM public.project_grants g
		    WHERE g.id=$1::uuid AND g.grantee_kind='user'
		  UNION
		  SELECT tm.user_id FROM public.project_grants g
		    JOIN public.team_members tm ON tm.team_id::text=g.grantee_id
		   WHERE g.id=$1::uuid AND g.grantee_kind='team'
		  UNION
		  SELECT gm.user_id FROM public.project_grants g
		    JOIN public.group_members gm ON gm.group_id::text=g.grantee_id
		   WHERE g.id=$1::uuid AND g.grantee_kind='group')
		SELECT m.user_id FROM members m
		  LEFT JOIN public.grant_key_wraps w ON w.grant_id=$1::uuid AND w.user_id=m.user_id
		 WHERE w.user_id IS NULL ORDER BY m.user_id`, grantID)
	if err != nil {
		return FulfilledResponse{}, err
	}
	defer rows.Close()
	missing := make([]string, 0)
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return FulfilledResponse{}, err
		}
		missing = append(missing, u)
	}
	return FulfilledResponse{Fulfilled: len(missing) == 0, Missing: missing}, rows.Err()
}
