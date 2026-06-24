/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   otp.go                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:34 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package loginotp

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// otp.go — the request/verify core. Request always succeeds to the caller (no email
// enumeration); Verify is constant-time, attempt-capped, single-use, and on success
// mints a short proof the login step requires.

// Request generates a 6-digit code, stores its peppered hash, and emails it. It NEVER
// reveals whether the email is registered (always returns nil to the caller); an email
// send failure is logged, not surfaced.
func (s *Service) Request(ctx context.Context, email string) error {
	code, err := genCode()
	if err != nil {
		return err
	}
	if err := s.insertCode(ctx, email, s.hashCode(email, code)); err != nil {
		return err
	}
	subject := "Your grobase sign-in code"
	body := fmt.Sprintf(
		"Your grobase verification code is %s\n\nIt expires in %d minutes. If you did not try to sign in, ignore this email.",
		code, int(s.ttl.Minutes()))
	if err := s.send(email, subject, body); err != nil {
		s.log.Warn("login otp email send failed", "err", err)
	}
	return nil
}

// Verify checks `code` against the latest live OTP for `email`: ErrExpired (410),
// ErrLocked (429), ErrInvalid (401), or — on a constant-time match — consumes it and
// returns a short proof token the login step requires.
func (s *Service) Verify(ctx context.Context, email, code string) (string, error) {
	row, err := s.latestLive(ctx, email)
	if err != nil {
		return "", err
	}
	if s.now().After(row.expiresAt) {
		return "", ErrExpired
	}
	if row.attempts >= s.maxAttempts {
		return "", ErrLocked
	}
	_ = s.bumpAttempt(ctx, row.id)
	if subtle.ConstantTimeCompare([]byte(s.hashCode(email, code)), []byte(row.codeHash)) != 1 {
		return "", ErrInvalid
	}
	if err := s.consume(ctx, row.id); err != nil {
		return "", err
	}
	return s.mintProof(email)
}

// genCode returns a uniformly-random 6-digit code (zero-padded) from the CSPRNG.
func genCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// hashCode is the peppered, email-bound code hash stored at rest (a DB leak is useless
// for offline guessing without the pepper).
func (s *Service) hashCode(email, code string) string {
	sum := sha256.Sum256([]byte(string(s.pepper) + ":" + strings.ToLower(email) + ":" + code))
	return hex.EncodeToString(sum[:])
}

// mintProof issues a short HS256 proof that `email` passed the OTP — the login step
// requires + verifies it.
func (s *Service) mintProof(email string) (string, error) {
	now := s.now()
	claims := jwt.MapClaims{
		"otp": strings.ToLower(email),
		"aud": "otp-proof",
		"iat": now.Unix(),
		"exp": now.Add(5 * time.Minute).Unix(),
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(s.jwtSecret)
}
