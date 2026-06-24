/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   jwt.go                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:06 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// JWTVerifier validates GoTrue-issued JWTs and extracts the subject.
//
// Default is HS256 with the shared GoTrue secret. Set `JWT_ALG=RS256` + a
// `JWKS_URL` (audit O2) to verify asymmetric tokens against rotating public
// keys instead — verify-only, the control plane never holds a private key.
// Either way the verifier pins to EXACTLY ONE algorithm (never a mix), so the
// algorithm-confusion / `none`-downgrade class is closed in both modes.
type JWTVerifier struct {
	alg    string      // "HS256" (default) or "RS256"
	secret []byte      // HS256 mode
	keys   *jwksKeyset // RS256 mode
	issuer string      // optional; if set, `iss` claim must match
}

// NewJWTVerifier builds a verifier. HS256 (default) uses `secret`; RS256
// (`JWT_ALG=RS256`) ignores `secret` and resolves keys from `JWKS_URL`. If
// issuer is non-empty, the JWT's `iss` claim must match it exactly.
func NewJWTVerifier(secret, issuer string) (*JWTVerifier, error) {
	alg := strings.ToUpper(strings.TrimSpace(os.Getenv("JWT_ALG")))
	if alg == "" {
		alg = "HS256"
	}
	v := &JWTVerifier{alg: alg, issuer: issuer}
	switch alg {
	case "HS256":
		if secret == "" {
			return nil, errors.New("jwt secret is required")
		}
		v.secret = []byte(secret)
	case "RS256":
		jwksURL := strings.TrimSpace(os.Getenv("JWKS_URL"))
		if jwksURL == "" {
			return nil, errors.New("JWT_ALG=RS256 requires JWKS_URL")
		}
		v.keys = newJwksKeyset(jwksURL)
	default:
		return nil, fmt.Errorf("unsupported JWT_ALG %q (want HS256 or RS256)", alg)
	}
	return v, nil
}

// VerifiedIdentity is the subset of GoTrue claims we care about.
type VerifiedIdentity struct {
	UserID string   // sub claim — GoTrue user UUID
	Email  string   // email claim
	Role   string   // role claim (e.g. "authenticated")
	Aud    []string // audience(s)
}

// Verify parses + validates a raw token string. Returns the identity on
// success or a descriptive error on failure.
func (v *JWTVerifier) Verify(raw string) (VerifiedIdentity, error) {
	raw = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(raw), "Bearer"))
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return VerifiedIdentity{}, errors.New("empty token")
	}
	token, err := jwt.Parse(raw, v.keyFunc, jwt.WithValidMethods([]string{v.alg}))
	if err != nil {
		return VerifiedIdentity{}, fmt.Errorf("parse: %w", err)
	}
	if !token.Valid {
		return VerifiedIdentity{}, errors.New("invalid token")
	}
	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return VerifiedIdentity{}, errors.New("unexpected claims type")
	}
	if err := v.validateClaims(claims); err != nil {
		return VerifiedIdentity{}, err
	}
	return identityFromClaims(claims), nil
}

// keyFunc resolves the verification key, pinning to the ONE configured algorithm
// — anything else (incl. `none` or an HS/RS swap) is rejected. This is the
// algorithm-confusion guard.
func (v *JWTVerifier) keyFunc(t *jwt.Token) (any, error) {
	if t.Method.Alg() != v.alg {
		return nil, fmt.Errorf("unexpected signing method: %s (want %s)", t.Method.Alg(), v.alg)
	}
	if v.alg == "RS256" {
		kid, _ := t.Header["kid"].(string)
		return v.keys.publicKey(kid)
	}
	return v.secret, nil
}

// validateClaims double-checks exp (jwt.Parse already does, but this yields a
// friendlier error for the common case), the issuer (when configured), and the
// presence of a subject.
func (v *JWTVerifier) validateClaims(claims jwt.MapClaims) error {
	if exp, err := claims.GetExpirationTime(); err == nil && exp != nil {
		if time.Now().After(exp.Time) {
			return errors.New("token expired")
		}
	}
	if v.issuer != "" {
		iss, _ := claims.GetIssuer()
		if iss != v.issuer {
			return fmt.Errorf("issuer mismatch: got %q want %q", iss, v.issuer)
		}
	}
	if sub, _ := claims.GetSubject(); sub == "" {
		return errors.New("missing sub claim")
	}
	return nil
}

// identityFromClaims projects the verified claims into a VerifiedIdentity.
func identityFromClaims(claims jwt.MapClaims) VerifiedIdentity {
	sub, _ := claims.GetSubject()
	email, _ := claims["email"].(string)
	role, _ := claims["role"].(string)
	aud, _ := claims.GetAudience()
	return VerifiedIdentity{UserID: sub, Email: email, Role: role, Aud: aud}
}
