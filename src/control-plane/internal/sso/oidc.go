package sso

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// httpTimeout bounds the IdP token + JWKS calls (an IdP that hangs must not hang
// a login). Net-new HTTP client, no shared state.
const httpTimeout = 10 * time.Second

// buildAuthorizeURL constructs the OIDC authorization-code redirect for a
// connection: response_type=code with scope "openid email profile", carrying the
// single-use state + nonce we minted. The IdP authenticates the user and
// redirects back to redirect_uri with ?code&state; the nonce comes back INSIDE
// the id_token (replay defense, verified in verifyIDToken).
func buildAuthorizeURL(c Connection, state, nonce string) string {
	q := url.Values{}
	q.Set("response_type", "code")
	q.Set("client_id", c.ClientID)
	q.Set("redirect_uri", c.RedirectURI)
	q.Set("scope", "openid email profile")
	q.Set("state", state)
	q.Set("nonce", nonce)
	sep := "?"
	if strings.Contains(c.AuthorizeURL, "?") {
		sep = "&"
	}
	return c.AuthorizeURL + sep + q.Encode()
}

// tokenResponse is the IdP token endpoint reply we read. We only need id_token
// (the JWT we verify); access_token/token_type are read for completeness.
type tokenResponse struct {
	IDToken     string `json:"id_token"`
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	Error       string `json:"error"`
	ErrorDesc   string `json:"error_description"`
}

// exchangeCode POSTs the authorization code to the IdP token endpoint
// (grant_type=authorization_code) and returns the raw id_token JWT. Client
// authentication is form-post (client_id + client_secret), the common OIDC
// confidential-client style the mock IdP and real IdPs both accept.
func exchangeCode(ctx context.Context, c Connection, code string) (string, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("redirect_uri", c.RedirectURI)
	form.Set("client_id", c.ClientID)
	if c.ClientSecret != "" {
		form.Set("client_secret", c.ClientSecret)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.TokenURL,
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: httpTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: token endpoint: %v", ErrTokenRejected, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%w: token endpoint status %d", ErrTokenRejected, resp.StatusCode)
	}
	var tr tokenResponse
	if err := json.Unmarshal(body, &tr); err != nil {
		return "", fmt.Errorf("%w: token endpoint body: %v", ErrTokenRejected, err)
	}
	if tr.Error != "" {
		return "", fmt.Errorf("%w: token endpoint error %s %s", ErrTokenRejected, tr.Error, tr.ErrorDesc)
	}
	if tr.IDToken == "" {
		return "", fmt.Errorf("%w: token endpoint returned no id_token", ErrTokenRejected)
	}
	return tr.IDToken, nil
}

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
	useRS256 := strings.TrimSpace(c.JWKSURL) != ""
	wantAlg := "HS256"
	if useRS256 {
		wantAlg = "RS256"
	}

	keyfunc := func(t *jwt.Token) (any, error) {
		if t.Method.Alg() != wantAlg {
			return nil, fmt.Errorf("unexpected signing method %s (want %s)", t.Method.Alg(), wantAlg)
		}
		if useRS256 {
			kid, _ := t.Header["kid"].(string)
			return fetchRSAKey(ctx, c.JWKSURL, kid)
		}
		// HS256: the client secret is the shared HMAC key.
		if c.ClientSecret == "" {
			return nil, errors.New("HS256 id_token verification needs the client secret")
		}
		return []byte(c.ClientSecret), nil
	}

	claims := jwt.MapClaims{}
	token, err := jwt.ParseWithClaims(rawIDToken, claims, keyfunc,
		jwt.WithValidMethods([]string{wantAlg}))
	if err != nil {
		return idTokenClaims{}, fmt.Errorf("%w: parse: %v", ErrTokenRejected, err)
	}
	if !token.Valid {
		return idTokenClaims{}, fmt.Errorf("%w: invalid token", ErrTokenRejected)
	}

	out := idTokenClaims{}
	if iss, _ := claims.GetIssuer(); iss != "" {
		out.Issuer = iss
	}
	if out.Issuer != c.Issuer {
		return idTokenClaims{}, fmt.Errorf("%w: issuer mismatch (got %q want %q)", ErrTokenRejected, out.Issuer, c.Issuer)
	}
	aud, _ := claims.GetAudience()
	out.Audience = aud
	if !audienceContains(aud, c.ClientID) {
		return idTokenClaims{}, fmt.Errorf("%w: audience does not contain client_id %q", ErrTokenRejected, c.ClientID)
	}
	if exp, err := claims.GetExpirationTime(); err == nil && exp != nil {
		if time.Now().After(exp.Time) {
			return idTokenClaims{}, fmt.Errorf("%w: token expired", ErrTokenRejected)
		}
		out.Expiry = exp.Time
	} else {
		return idTokenClaims{}, fmt.Errorf("%w: id_token missing exp", ErrTokenRejected)
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

func audienceContains(aud []string, want string) bool {
	for _, a := range aud {
		if a == want {
			return true
		}
	}
	return false
}

// jwksDoc / jwksKey model the minimal JWKS JSON we parse: RSA keys carry kty=RSA,
// a b64url modulus n and exponent e, and an optional kid we match against the
// token header.
type jwksDoc struct {
	Keys []jwksKey `json:"keys"`
}
type jwksKey struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// fetchRSAKey GETs the JWKS document and reconstructs the *rsa.PublicKey for the
// requested kid (or the sole RSA key when kid is empty / unmatched-but-unique).
// We build the key from the b64url n/e ourselves with crypto/rsa + math/big — no
// new dependency, the same shape tenants/jwks.go uses for the gateway path.
func fetchRSAKey(ctx context.Context, jwksURL, kid string) (*rsa.PublicKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, jwksURL, nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: httpTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("jwks fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks fetch status %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var doc jwksDoc
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("jwks parse: %w", err)
	}
	var chosen *jwksKey
	for i := range doc.Keys {
		k := &doc.Keys[i]
		if k.Kty != "RSA" {
			continue
		}
		if kid == "" || k.Kid == kid {
			chosen = k
			break
		}
		if chosen == nil {
			chosen = k // fallback: first RSA key if no kid match
		}
	}
	if chosen == nil {
		return nil, errors.New("jwks: no RSA key found")
	}
	return rsaFromNE(chosen.N, chosen.E)
}

// rsaFromNE builds an *rsa.PublicKey from the JWKS b64url-encoded modulus (n) and
// exponent (e).
func rsaFromNE(nB64, eB64 string) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(nB64, "="))
	if err != nil {
		return nil, fmt.Errorf("jwks: bad modulus: %w", err)
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(eB64, "="))
	if err != nil {
		return nil, fmt.Errorf("jwks: bad exponent: %w", err)
	}
	n := new(big.Int).SetBytes(nBytes)
	e := new(big.Int).SetBytes(eBytes)
	if !e.IsInt64() || e.Int64() <= 0 {
		return nil, errors.New("jwks: invalid exponent")
	}
	return &rsa.PublicKey{N: n, E: int(e.Int64())}, nil
}
