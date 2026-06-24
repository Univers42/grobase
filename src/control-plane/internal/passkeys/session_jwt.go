/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   session_jwt.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:27 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:28 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package passkeys

import (
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// SessionMinter mints the session token a successful passkey login returns. It
// produces a GoTrue-shaped HS256 JWT verifiable by the EXISTING
// tenants.JWTVerifier (same secret, same claim shape: sub/email/role/aud/exp),
// so a passkey session is interchangeable with a password session — no new
// verifier, no second algorithm. HS256 is pinned to mirror the verifier's
// default; an RS256 mint would need a private key the control plane intentionally
// does not hold (the verifier is verify-only in RS256 mode).
type SessionMinter struct {
	secret []byte
	issuer string
	ttl    time.Duration
}

// NewSessionMinter builds the minter. secret is the shared GoTrue HS256 secret
// (GOTRUE_JWT_SECRET / JWT_SECRET); issuer is stamped as `iss` when non-empty
// (so a verifier configured with GOTRUE_JWT_ISSUER accepts the token); ttl
// defaults to one hour when non-positive.
func NewSessionMinter(secret, issuer string, ttl time.Duration) *SessionMinter {
	if ttl <= 0 {
		ttl = time.Hour
	}
	return &SessionMinter{secret: []byte(secret), issuer: issuer, ttl: ttl}
}

// MintedSession is the login/finish payload: the bearer token + its metadata.
type MintedSession struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int64  `json:"expires_in"`
	ExpiresAt   int64  `json:"expires_at"`
	UserID      string `json:"user_id"`
}

// Mint issues a session JWT for the authenticated user. The claims mirror
// GoTrue: sub (user id), email, role=authenticated, aud=authenticated, iat/exp
// (and iss when configured). Pinned to HS256 — the one algorithm the default
// verifier accepts.
func (m *SessionMinter) Mint(userID, email string) (MintedSession, error) {
	if len(m.secret) == 0 {
		return MintedSession{}, errNoSecret
	}
	now := time.Now()
	exp := now.Add(m.ttl)
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, m.claims(userID, email, now, exp))
	signed, err := tok.SignedString(m.secret)
	if err != nil {
		return MintedSession{}, err
	}
	return MintedSession{
		AccessToken: signed,
		TokenType:   "bearer",
		ExpiresIn:   int64(m.ttl.Seconds()),
		ExpiresAt:   exp.Unix(),
		UserID:      userID,
	}, nil
}

// claims builds the GoTrue-shaped HS256 claim set (sub/email/role/aud/iat/exp,
// amr=webauthn, and iss when configured).
func (m *SessionMinter) claims(userID, email string, now, exp time.Time) jwt.MapClaims {
	claims := jwt.MapClaims{
		"sub":   userID,
		"email": email,
		"role":  "authenticated",
		"aud":   "authenticated",
		"iat":   now.Unix(),
		"exp":   exp.Unix(),
		"amr":   []map[string]any{{"method": "webauthn", "timestamp": now.Unix()}},
	}
	if m.issuer != "" {
		claims["iss"] = m.issuer
	}
	return claims
}
