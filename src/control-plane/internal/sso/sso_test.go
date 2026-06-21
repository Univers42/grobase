/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sso_test.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:56:45 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:56:47 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package sso

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
	"github.com/golang-jwt/jwt/v5"
)

// ── state store: single-use + TTL ─────────────────────────────────────────────

func TestStateStore_SingleUse(t *testing.T) {
	s := newStateStore()
	id, err := s.put(loginState{connID: "c1", nonce: "n1"})
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	got, ok := s.take(id)
	if !ok || got.connID != "c1" || got.nonce != "n1" {
		t.Fatalf("first take should succeed with the stored state, got ok=%v %+v", ok, got)
	}
	if _, ok := s.take(id); ok {
		t.Fatalf("second take of the same state MUST fail (single-use)")
	}
}

func TestStateStore_TTLExpiry(t *testing.T) {
	s := newStateStore()
	base := time.Now()
	s.now = func() time.Time { return base }
	id, err := s.put(loginState{connID: "c1", nonce: "n1"})
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	// advance past the TTL.
	s.now = func() time.Time { return base.Add(stateTTL + time.Second) }
	if _, ok := s.take(id); ok {
		t.Fatalf("an expired state MUST NOT be takeable")
	}
}

func TestStateStore_UnknownState(t *testing.T) {
	s := newStateStore()
	if _, ok := s.take("does-not-exist"); ok {
		t.Fatalf("an unknown state MUST return ok=false")
	}
}

// ── crypto: seal/open round-trip + tamper rejection ───────────────────────────

func TestSecretSealer_RoundTrip(t *testing.T) {
	sealer, err := newSecretSealer("a-sufficiently-long-operator-key")
	if err != nil {
		t.Fatalf("newSecretSealer: %v", err)
	}
	blob, err := sealer.seal("super-secret-client-secret")
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	got, err := sealer.open(blob)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if got != "super-secret-client-secret" {
		t.Fatalf("round-trip mismatch: got %q", got)
	}
}

func TestSecretSealer_TamperRejected(t *testing.T) {
	sealer, _ := newSecretSealer("a-sufficiently-long-operator-key")
	blob, _ := sealer.seal("secret")
	blob[len(blob)-1] ^= 0xff // flip the last byte of the auth tag
	if _, err := sealer.open(blob); err == nil {
		t.Fatalf("opening a tampered blob MUST fail (GCM auth)")
	}
}

func TestSecretSealer_EmptyKeyRejected(t *testing.T) {
	if _, err := newSecretSealer(""); err == nil {
		t.Fatalf("an empty SSO_SECRET_KEY MUST be rejected")
	}
}

// ── id_token verify: HS256 happy + reject vectors ─────────────────────────────

const (
	testIssuer   = "https://idp.example.com"
	testClientID = "grobase-client-id"
	testSecret   = "the-oidc-client-secret-shared-hmac"
	testNonce    = "the-login-nonce"
	testSub      = "user-subject-123"
	testEmail    = "alice@example.com"
)

func hsToken(t *testing.T, secret string, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	s, err := tok.SignedString([]byte(secret))
	if err != nil {
		t.Fatalf("sign hs256: %v", err)
	}
	return s
}

func goodClaims() jwt.MapClaims {
	return jwt.MapClaims{
		"iss":   testIssuer,
		"aud":   testClientID,
		"sub":   testSub,
		"email": testEmail,
		"nonce": testNonce,
		"exp":   time.Now().Add(time.Hour).Unix(),
		"iat":   time.Now().Unix(),
	}
}

func hsConn() Connection {
	return Connection{
		Issuer:       testIssuer,
		ClientID:     testClientID,
		ClientSecret: testSecret,
		// JWKSURL empty => HS256 mode.
	}
}

func TestVerifyIDToken_HS256_Happy(t *testing.T) {
	raw := hsToken(t, testSecret, goodClaims())
	got, err := verifyIDToken(context.Background(), hsConn(), raw, testNonce)
	if err != nil {
		t.Fatalf("verify happy: %v", err)
	}
	if got.Subject != testSub || got.Email != testEmail {
		t.Fatalf("claims mismatch: %+v", got)
	}
}

func TestVerifyIDToken_WrongSecretRejected(t *testing.T) {
	raw := hsToken(t, "a-completely-different-secret", goodClaims())
	if _, err := verifyIDToken(context.Background(), hsConn(), raw, testNonce); err == nil {
		t.Fatalf("a token signed with the WRONG key MUST be rejected")
	}
}

func TestVerifyIDToken_WrongIssuerRejected(t *testing.T) {
	c := goodClaims()
	c["iss"] = "https://evil-idp.example.com"
	raw := hsToken(t, testSecret, c)
	if _, err := verifyIDToken(context.Background(), hsConn(), raw, testNonce); err == nil {
		t.Fatalf("a wrong-issuer token MUST be rejected")
	}
}

func TestVerifyIDToken_WrongAudienceRejected(t *testing.T) {
	c := goodClaims()
	c["aud"] = "some-other-client"
	raw := hsToken(t, testSecret, c)
	if _, err := verifyIDToken(context.Background(), hsConn(), raw, testNonce); err == nil {
		t.Fatalf("a wrong-audience token MUST be rejected")
	}
}

func TestVerifyIDToken_ExpiredRejected(t *testing.T) {
	c := goodClaims()
	c["exp"] = time.Now().Add(-time.Hour).Unix()
	raw := hsToken(t, testSecret, c)
	if _, err := verifyIDToken(context.Background(), hsConn(), raw, testNonce); err == nil {
		t.Fatalf("an expired token MUST be rejected")
	}
}

func TestVerifyIDToken_NonceMismatchRejected(t *testing.T) {
	raw := hsToken(t, testSecret, goodClaims())
	if _, err := verifyIDToken(context.Background(), hsConn(), raw, "a-different-nonce"); err == nil {
		t.Fatalf("a nonce mismatch MUST be rejected (replay defense)")
	}
}

// ── id_token verify: RS256 via JWKS round-trip ────────────────────────────────

func TestVerifyIDToken_RS256_JWKSRoundTrip(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("genkey: %v", err)
	}
	const kid = "test-kid-1"

	// Serve a JWKS document with this RSA public key.
	jwksJSON := func() []byte {
		n := base64.RawURLEncoding.EncodeToString(key.N.Bytes())
		e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())
		doc := jwksDoc{Keys: []jwksKey{{Kty: "RSA", Kid: kid, N: n, E: e}}}
		b, _ := json.Marshal(doc)
		return b
	}()
	jwks := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(jwksJSON)
	}))
	defer jwks.Close()

	// Sign an id_token with the private key (RS256), kid in the header.
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, goodClaims())
	tok.Header["kid"] = kid
	raw, err := tok.SignedString(key)
	if err != nil {
		t.Fatalf("sign rs256: %v", err)
	}

	conn := Connection{Issuer: testIssuer, ClientID: testClientID, JWKSURL: jwks.URL}
	got, err := verifyIDToken(context.Background(), conn, raw, testNonce)
	if err != nil {
		t.Fatalf("RS256 verify: %v", err)
	}
	if got.Subject != testSub {
		t.Fatalf("RS256 sub mismatch: %+v", got)
	}

	// A token signed with a DIFFERENT RSA key MUST be rejected even with a valid
	// JWKS — proves the signature, not just the JWKS fetch, is load-bearing.
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	tok2 := jwt.NewWithClaims(jwt.SigningMethodRS256, goodClaims())
	tok2.Header["kid"] = kid
	raw2, _ := tok2.SignedString(other)
	if _, err := verifyIDToken(context.Background(), conn, raw2, testNonce); err == nil {
		t.Fatalf("an RS256 token signed by the WRONG key MUST be rejected")
	}
}

// ── the minted session JWT round-trips under tenants.JWTVerifier ──────────────

func TestMintedSession_VerifiesUnderJWTVerifier(t *testing.T) {
	secret := "the-shared-gotrue-hs256-secret-do-not-use"
	minter := NewSessionMinter(secret, "", 0)
	session, err := minter.Mint(testSub, testEmail)
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	v, err := tenants.NewJWTVerifier(secret, "")
	if err != nil {
		t.Fatalf("verifier: %v", err)
	}
	id, err := v.Verify(session.AccessToken)
	if err != nil {
		t.Fatalf("an SSO-minted session MUST verify under tenants.JWTVerifier: %v", err)
	}
	if id.UserID != testSub || id.Email != testEmail || id.Role != "authenticated" {
		t.Fatalf("verified identity mismatch: %+v", id)
	}
}
