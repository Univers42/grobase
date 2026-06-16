package sso

import (
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// SessionMinter mints the session token a successful SSO login returns. It
// produces a GoTrue-shaped HS256 JWT verifiable by the EXISTING
// tenants.JWTVerifier (same secret, same claim shape: sub/email/role/aud/exp), so
// an SSO session is interchangeable with a password or passkey session — no new
// verifier, no second algorithm. This is the SAME pattern internal/passkeys uses
// (passkeys.SessionMinter); it lives in-package so the sso package is
// self-contained. HS256 is pinned to mirror the verifier's default; an RS256 mint
// would need a private key the control plane intentionally does not hold (the
// verifier is verify-only in RS256 mode).
type SessionMinter struct {
	secret []byte
	issuer string
	ttl    time.Duration
}

// errNoSecret guards minting — an SSO login cannot issue a session without the
// shared GoTrue secret. main.go only enables the SSO API when the secret is
// configured, so this is a programmer-error backstop.
var errNoSecret = errors.New("sso: session secret not configured")

// NewSessionMinter builds the minter. secret is the shared GoTrue HS256 secret
// (GOTRUE_JWT_SECRET / JWT_SECRET); issuer is stamped as `iss` when non-empty (so
// a verifier configured with GOTRUE_JWT_ISSUER accepts the token); ttl defaults
// to one hour when non-positive.
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
	Email       string `json:"email,omitempty"`
}

// Mint issues a session JWT for the SSO'd user. The claims mirror GoTrue: sub
// (user id), email, role=authenticated, aud=authenticated, iat/exp (and iss when
// configured), plus an `amr` method=sso marker. Pinned to HS256 — the one
// algorithm the default verifier accepts.
func (m *SessionMinter) Mint(userID, email string) (MintedSession, error) {
	if len(m.secret) == 0 {
		return MintedSession{}, errNoSecret
	}
	now := time.Now()
	exp := now.Add(m.ttl)
	claims := jwt.MapClaims{
		"sub":   userID,
		"email": email,
		"role":  "authenticated",
		"aud":   "authenticated",
		"iat":   now.Unix(),
		"exp":   exp.Unix(),
		"amr":   []map[string]any{{"method": "sso", "timestamp": now.Unix()}},
	}
	if m.issuer != "" {
		claims["iss"] = m.issuer
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
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
		Email:       email,
	}, nil
}
