package tenants

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const testSecret = "dev-test-jwt-secret-please-do-not-use-in-prod"

func signTestToken(t *testing.T, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := tok.SignedString([]byte(testSecret))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signed
}

func TestJWTVerifier_Valid(t *testing.T) {
	v, err := NewJWTVerifier(testSecret, "")
	if err != nil {
		t.Fatal(err)
	}
	tok := signTestToken(t, jwt.MapClaims{
		"sub":   "11111111-2222-3333-4444-555555555555",
		"email": "user@example.com",
		"role":  "authenticated",
		"exp":   time.Now().Add(1 * time.Hour).Unix(),
	})
	id, err := v.Verify(tok)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if id.UserID != "11111111-2222-3333-4444-555555555555" {
		t.Errorf("sub: %q", id.UserID)
	}
	if id.Email != "user@example.com" {
		t.Errorf("email: %q", id.Email)
	}
}

func TestJWTVerifier_BearerPrefixStripped(t *testing.T) {
	v, _ := NewJWTVerifier(testSecret, "")
	tok := signTestToken(t, jwt.MapClaims{
		"sub": "u-1",
		"exp": time.Now().Add(time.Hour).Unix(),
	})
	if _, err := v.Verify("Bearer " + tok); err != nil {
		t.Errorf("Bearer prefix should be tolerated: %v", err)
	}
}

func TestJWTVerifier_Expired(t *testing.T) {
	v, _ := NewJWTVerifier(testSecret, "")
	tok := signTestToken(t, jwt.MapClaims{
		"sub": "u-1",
		"exp": time.Now().Add(-1 * time.Minute).Unix(),
	})
	if _, err := v.Verify(tok); err == nil {
		t.Error("expected expired token to be rejected")
	}
}

func TestJWTVerifier_WrongSecret(t *testing.T) {
	v, _ := NewJWTVerifier("a-different-secret", "")
	tok := signTestToken(t, jwt.MapClaims{
		"sub": "u-1",
		"exp": time.Now().Add(time.Hour).Unix(),
	})
	if _, err := v.Verify(tok); err == nil {
		t.Error("expected signature mismatch to be rejected")
	}
}

func TestJWTVerifier_RejectsNoneAlg(t *testing.T) {
	// Forge a `none`-alg token (header + payload base64 + empty signature).
	tok := jwt.NewWithClaims(jwt.SigningMethodNone, jwt.MapClaims{
		"sub": "u-1",
		"exp": time.Now().Add(time.Hour).Unix(),
	})
	signed, _ := tok.SignedString(jwt.UnsafeAllowNoneSignatureType)
	v, _ := NewJWTVerifier(testSecret, "")
	if _, err := v.Verify(signed); err == nil {
		t.Error("alg=none must be rejected")
	}
}

func TestJWTVerifier_MissingSub(t *testing.T) {
	v, _ := NewJWTVerifier(testSecret, "")
	tok := signTestToken(t, jwt.MapClaims{
		"email": "user@example.com",
		"exp":   time.Now().Add(time.Hour).Unix(),
	})
	if _, err := v.Verify(tok); err == nil {
		t.Error("missing sub must be rejected")
	}
}

func TestJWTVerifier_IssuerMismatch(t *testing.T) {
	v, _ := NewJWTVerifier(testSecret, "https://issuer.example.com")
	tok := signTestToken(t, jwt.MapClaims{
		"sub": "u-1",
		"iss": "https://wrong.example.com",
		"exp": time.Now().Add(time.Hour).Unix(),
	})
	if _, err := v.Verify(tok); err == nil {
		t.Error("wrong issuer must be rejected")
	}
}
