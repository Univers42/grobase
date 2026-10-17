/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:39 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:41 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package loginotp

import (
	"context"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// store.go — login_otps persistence (admin pool). The code itself is never stored;
// only its peppered hash.

// otpStore is the persistence the request/verify core needs; pgStore is the
// production implementation, tests substitute an in-memory one.
type otpStore interface {
	insertCode(ctx context.Context, email, hash string, expiresAt time.Time) error
	latestLive(ctx context.Context, email string) (otpRow, error)
	bumpAttempt(ctx context.Context, id string) error
	consume(ctx context.Context, id string) error
}

// pgStore backs otpStore with the admin pool.
type pgStore struct{ db *pg.Postgres }

// otpRow is the latest live code's state for verification.
type otpRow struct {
	id        string
	codeHash  string
	attempts  int
	expiresAt time.Time
}

// insertCode stores a fresh code hash for email, valid until expiresAt.
func (s pgStore) insertCode(ctx context.Context, email, hash string, expiresAt time.Time) error {
	return s.db.AdminExec(ctx,
		`INSERT INTO public.login_otps (email, code_hash, expires_at) VALUES ($1, $2, $3)`,
		email, hash, expiresAt.UTC())
}

// latestLive reads the most recent unconsumed code for email (ErrNoCode if none).
func (s pgStore) latestLive(ctx context.Context, email string) (otpRow, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT id::text, code_hash, attempts, expires_at
		  FROM public.login_otps WHERE lower(email)=lower($1) AND consumed_at IS NULL
		 ORDER BY created_at DESC LIMIT 1`, email)
	if err != nil {
		return otpRow{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		return otpRow{}, ErrNoCode
	}
	var r otpRow
	if err := rows.Scan(&r.id, &r.codeHash, &r.attempts, &r.expiresAt); err != nil {
		return otpRow{}, err
	}
	return r, nil
}

// bumpAttempt increments the attempt counter (the attempt cap is checked before this).
func (s pgStore) bumpAttempt(ctx context.Context, id string) error {
	return s.db.AdminExec(ctx, `UPDATE public.login_otps SET attempts=attempts+1 WHERE id::text=$1`, id)
}

// consume marks a code used (single-use).
func (s pgStore) consume(ctx context.Context, id string) error {
	return s.db.AdminExec(ctx, `UPDATE public.login_otps SET consumed_at=now() WHERE id::text=$1`, id)
}
