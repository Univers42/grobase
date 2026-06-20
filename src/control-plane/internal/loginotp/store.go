package loginotp

import (
	"context"
	"time"
)

// store.go — login_otps persistence (admin pool). The code itself is never stored;
// only its peppered hash.

// otpRow is the latest live code's state for verification.
type otpRow struct {
	id        string
	codeHash  string
	attempts  int
	expiresAt time.Time
}

// insertCode stores a fresh code hash for email with a TTL.
func (s *Service) insertCode(ctx context.Context, email, hash string) error {
	return s.db.AdminExec(ctx,
		`INSERT INTO public.login_otps (email, code_hash, expires_at) VALUES ($1, $2, $3)`,
		email, hash, s.now().UTC().Add(s.ttl))
}

// latestLive reads the most recent unconsumed code for email (ErrNoCode if none).
func (s *Service) latestLive(ctx context.Context, email string) (otpRow, error) {
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
func (s *Service) bumpAttempt(ctx context.Context, id string) error {
	return s.db.AdminExec(ctx, `UPDATE public.login_otps SET attempts=attempts+1 WHERE id::text=$1`, id)
}

// consume marks a code used (single-use).
func (s *Service) consume(ctx context.Context, id string) error {
	return s.db.AdminExec(ctx, `UPDATE public.login_otps SET consumed_at=now() WHERE id::text=$1`, id)
}
