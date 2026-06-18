package sso

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// verifyIDToken parses + cryptographically verifies the id_token and validates
// the OIDC claims. Supports BOTH:
//   - HS256: the client secret is the shared HMAC key (dev / the mock IdP).
//   - RS256: the public key is fetched from the connection's jwks_url and matched
//     by `kid`; we parse the JWKS JSON ourselves (crypto/rsa + math/big from the
//     n/e b64url) — no new dependency.
//
// The signing method is pinned to EXACTLY ONE algorithm per connection (HS256
// when jwks_url is empty, else RS256), so the alg-confusion / `none`-downgrade
// class is closed (same discipline as tenants.JWTVerifier). After signature
// verification we validate: iss == connection.issuer, aud contains client_id,
// exp not past, nonce == the per-login nonce. Any failure returns ErrTokenRejected.
func verifyIDToken(ctx context.Context, c Connection, rawIDToken, wantNonce string) (idTokenClaims, error) {
	wantAlg := "HS256"
	if strings.TrimSpace(c.JWKSURL) != "" {
		wantAlg = "RS256"
	}
	claims := jwt.MapClaims{}
	token, err := jwt.ParseWithClaims(rawIDToken, claims, idTokenKeyfunc(ctx, c, wantAlg),
		jwt.WithValidMethods([]string{wantAlg}))
	if err != nil {
		return idTokenClaims{}, fmt.Errorf("%w: parse: %v", ErrTokenRejected, err)
	}
	if !token.Valid {
		return idTokenClaims{}, fmt.Errorf("%w: invalid token", ErrTokenRejected)
	}
	return validateClaims(c, claims, wantNonce)
}

// idTokenKeyfunc returns the jwt.Keyfunc pinned to exactly wantAlg: RS256 fetches
// the *rsa.PublicKey from the connection's JWKS by kid; HS256 uses the client
// secret as the shared HMAC key. The single-alg pin closes the alg-confusion class.
func idTokenKeyfunc(ctx context.Context, c Connection, wantAlg string) jwt.Keyfunc {
	return func(t *jwt.Token) (any, error) {
		if t.Method.Alg() != wantAlg {
			return nil, fmt.Errorf("unexpected signing method %s (want %s)", t.Method.Alg(), wantAlg)
		}
		if wantAlg == "RS256" {
			kid, _ := t.Header["kid"].(string)
			return fetchRSAKey(ctx, c.JWKSURL, kid)
		}
		if c.ClientSecret == "" {
			return nil, errors.New("HS256 id_token verification needs the client secret")
		}
		return []byte(c.ClientSecret), nil
	}
}

// validateClaims checks iss/aud/exp/nonce/sub against the connection and extracts
// the resolved identity. Any failure is ErrTokenRejected (no session minted).
func validateClaims(c Connection, claims jwt.MapClaims, wantNonce string) (idTokenClaims, error) {
	out := idTokenClaims{}
	if iss, _ := claims.GetIssuer(); iss != "" {
		out.Issuer = iss
	}
	if out.Issuer != c.Issuer {
		return idTokenClaims{}, fmt.Errorf("%w: issuer mismatch (got %q want %q)", ErrTokenRejected, out.Issuer, c.Issuer)
	}
	out.Audience, _ = claims.GetAudience()
	if !audienceContains(out.Audience, c.ClientID) {
		return idTokenClaims{}, fmt.Errorf("%w: audience does not contain client_id %q", ErrTokenRejected, c.ClientID)
	}
	if err := checkExpiry(claims, &out); err != nil {
		return idTokenClaims{}, err
	}
	out.Nonce, _ = claims["nonce"].(string)
	if wantNonce != "" && out.Nonce != wantNonce {
		return idTokenClaims{}, fmt.Errorf("%w: nonce mismatch", ErrTokenRejected)
	}
	out.Subject, _ = claims.GetSubject()
	if out.Subject == "" {
		return idTokenClaims{}, fmt.Errorf("%w: id_token missing sub", ErrTokenRejected)
	}
	out.Email, _ = claims["email"].(string)
	return out, nil
}

// checkExpiry rejects a missing or past `exp` and records it on out.
func checkExpiry(claims jwt.MapClaims, out *idTokenClaims) error {
	exp, err := claims.GetExpirationTime()
	if err != nil || exp == nil {
		return fmt.Errorf("%w: id_token missing exp", ErrTokenRejected)
	}
	if time.Now().After(exp.Time) {
		return fmt.Errorf("%w: token expired", ErrTokenRejected)
	}
	out.Expiry = exp.Time
	return nil
}

func audienceContains(aud []string, want string) bool {
	for _, a := range aud {
		if a == want {
			return true
		}
	}
	return false
}
