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
	"strings"
)

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
	doc, err := fetchJWKS(ctx, jwksURL)
	if err != nil {
		return nil, err
	}
	chosen := pickRSAKey(doc.Keys, kid)
	if chosen == nil {
		return nil, errors.New("jwks: no RSA key found")
	}
	return rsaFromNE(chosen.N, chosen.E)
}

// fetchJWKS GETs and decodes the JWKS document (bounded read).
func fetchJWKS(ctx context.Context, jwksURL string) (jwksDoc, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, jwksURL, nil)
	if err != nil {
		return jwksDoc{}, err
	}
	client := &http.Client{Timeout: httpTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return jwksDoc{}, fmt.Errorf("jwks fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return jwksDoc{}, fmt.Errorf("jwks fetch status %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var doc jwksDoc
	if err := json.Unmarshal(body, &doc); err != nil {
		return jwksDoc{}, fmt.Errorf("jwks parse: %w", err)
	}
	return doc, nil
}

// pickRSAKey selects the RSA key matching kid, falling back to the first RSA key
// when kid is empty or unmatched. Returns nil when no RSA key is present.
// pickRSAKey returns the RSA key whose kid matches (or the first RSA key when kid
// is empty); when no kid matches it falls back to the first RSA key seen.
func pickRSAKey(keys []jwksKey, kid string) *jwksKey {
	var chosen *jwksKey
	for i := range keys {
		k := &keys[i]
		if k.Kty != "RSA" {
			continue
		}
		if kid == "" || k.Kid == kid {
			return k
		}
		if chosen == nil {
			chosen = k
		}
	}
	return chosen
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
