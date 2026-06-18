package tenants

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// jwksServer serves a single-key JWKS document for the given RSA public key.
func jwksServer(t *testing.T, kid string, pub *rsa.PublicKey) *httptest.Server {
	t.Helper()
	n := base64.RawURLEncoding.EncodeToString(pub.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes())
	doc := map[string]any{"keys": []map[string]string{
		{"kty": "RSA", "kid": kid, "alg": "RS256", "use": "sig", "n": n, "e": e},
	}}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(doc)
	}))
}

func TestJWTVerifier_RS256_ViaJWKS(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	srv := jwksServer(t, "key-1", &key.PublicKey)
	defer srv.Close()

	t.Setenv("JWT_ALG", "RS256")
	t.Setenv("JWKS_URL", srv.URL)
	v, err := NewJWTVerifier("", "") // secret ignored in RS256 mode
	if err != nil {
		t.Fatalf("NewJWTVerifier RS256: %v", err)
	}

	// A valid RS256 token (with kid) verifies + yields the subject.
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"sub":   "user-rs256",
		"email": "rs@example.com",
		"exp":   time.Now().Add(time.Hour).Unix(),
	})
	tok.Header["kid"] = "key-1"
	signed, err := tok.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	id, err := v.Verify(signed)
	if err != nil {
		t.Fatalf("RS256 verify: %v", err)
	}
	if id.UserID != "user-rs256" || id.Email != "rs@example.com" {
		t.Fatalf("unexpected identity: %+v", id)
	}

	// Algorithm-confusion: an HS256 token signed with the JWKS modulus bytes as
	// the "secret" must be REJECTED in RS256 mode (the classic RS→HS attack).
	hs := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": "attacker", "exp": time.Now().Add(time.Hour).Unix(),
	})
	hsSigned, _ := hs.SignedString(key.PublicKey.N.Bytes())
	if _, err := v.Verify(hsSigned); err == nil {
		t.Fatal("RS256 verifier accepted an HS256 token (algorithm-confusion hole)")
	}

	// An unknown kid is rejected (no key, no panic).
	tok2 := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"sub": "x", "exp": time.Now().Add(time.Hour).Unix(),
	})
	tok2.Header["kid"] = "nope"
	bad, _ := tok2.SignedString(key)
	if _, err := v.Verify(bad); err == nil {
		t.Fatal("accepted a token with an unknown kid")
	}
}

func TestJWTVerifier_RS256_RequiresJWKSURL(t *testing.T) {
	t.Setenv("JWT_ALG", "RS256")
	t.Setenv("JWKS_URL", "")
	if _, err := NewJWTVerifier("secret", ""); err == nil {
		t.Fatal("RS256 without JWKS_URL must error")
	}
}

func TestJWTVerifier_DefaultsToHS256(t *testing.T) {
	// No JWT_ALG env → HS256 path, byte-for-byte the original behavior.
	t.Setenv("JWT_ALG", "")
	v, err := NewJWTVerifier(testSecret, "")
	if err != nil {
		t.Fatalf("default HS256: %v", err)
	}
	if v.alg != "HS256" {
		t.Fatalf("default alg = %q, want HS256", v.alg)
	}
}
