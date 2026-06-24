package oauth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"
)

// Token is the client_credentials response body returned to the caller.
type Token struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int    `json:"expires_in"`
}

// claims is the minimal HS256 payload: subject, audience, expiry. For the
// client-credentials grant the subject is the client id (no end user).
type claims struct {
	Sub string `json:"sub"`
	Aud string `json:"aud"`
	Exp int64  `json:"exp"`
}

// Mint signs a short-lived HS256 token for sub with aud=Audience, returning the
// response envelope (token_type bearer, expires_in seconds).
func (i *Issuer) Mint(sub string) (Token, error) {
	exp := time.Now().Add(tokenTTL)
	payload := claims{Sub: sub, Aud: Audience, Exp: exp.Unix()}
	signed, err := i.sign(payload)
	if err != nil {
		return Token{}, err
	}
	return Token{AccessToken: signed, TokenType: "bearer", ExpiresIn: int(tokenTTL.Seconds())}, nil
}

// sign serializes the fixed HS256 header + payload and appends the HMAC signature.
func (i *Issuer) sign(c claims) (string, error) {
	header := b64(`{"alg":"HS256","typ":"JWT"}`)
	body, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	signingInput := header + "." + b64(string(body))
	return signingInput + "." + i.mac(signingInput), nil
}

// mac returns the base64url HMAC-SHA256 of input under the JWT secret.
func (i *Issuer) mac(input string) string {
	h := hmac.New(sha256.New, i.jwtSecret)
	h.Write([]byte(input))
	return base64.RawURLEncoding.EncodeToString(h.Sum(nil))
}

// b64 base64url-encodes a string without padding (JWT segment encoding).
func b64(s string) string { return base64.RawURLEncoding.EncodeToString([]byte(s)) }

// split returns the three dot-separated JWT segments, or false if malformed.
func split(token string) (header, payload, sig string, ok bool) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", "", "", false
	}
	return parts[0], parts[1], parts[2], true
}
