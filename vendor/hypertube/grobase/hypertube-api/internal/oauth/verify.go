package oauth

import (
	"crypto/hmac"
	"encoding/base64"
	"encoding/json"
	"time"
)

// Verify checks token's HS256 signature, audience, and expiry, returning the
// subject. A bad signature, wrong aud, expired token, or malformed shape yields
// the verifyError type so callers map every failure to a single 401.
func (i *Issuer) Verify(token string) (string, error) {
	header, payload, sig, ok := split(token)
	if !ok {
		return "", verifyError("malformed token")
	}
	if !hmac.Equal([]byte(i.mac(header+"."+payload)), []byte(sig)) {
		return "", verifyError("bad signature")
	}
	c, err := decodeClaims(payload)
	if err != nil {
		return "", verifyError("malformed claims")
	}
	if c.Aud != Audience || time.Now().Unix() >= c.Exp {
		return "", verifyError("invalid audience or expired")
	}
	return c.Sub, nil
}

// decodeClaims base64url-decodes and unmarshals the JWT payload segment.
func decodeClaims(payload string) (claims, error) {
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return claims{}, err
	}
	var c claims
	if err := json.Unmarshal(raw, &c); err != nil {
		return claims{}, err
	}
	return c, nil
}

// verifyError is a token-verification failure modelled as a const-friendly error
// type (no sentinel var — see .claude/rules/no-globals.md).
type verifyError string

// Error renders the verification failure reason (caller maps all to 401).
func (e verifyError) Error() string { return string(e) }
