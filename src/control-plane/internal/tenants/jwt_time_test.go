package tenants

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// verifyWith builds an HS256 verifier and verifies a token signed over claims.
func verifyWith(t *testing.T, claims jwt.MapClaims) error {
	t.Helper()
	v, err := NewJWTVerifier(testSecret, "")
	if err != nil {
		t.Fatal(err)
	}
	_, err = v.Verify(signTestToken(t, claims))
	return err
}

// TestJWTVerifier_TimeClaims is M-3: exp is required (a token without it never
// expires), and iat/nbf later than now + leeway are refused.
func TestJWTVerifier_TimeClaims(t *testing.T) {
	now := time.Now()
	cases := []struct {
		name   string
		claims jwt.MapClaims
		ok     bool
	}{
		{"exp and iat now", jwt.MapClaims{"sub": "u", "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()}, true},
		{"no exp", jwt.MapClaims{"sub": "u", "iat": now.Unix()}, false},
		{"iat an hour ahead", jwt.MapClaims{"sub": "u", "iat": now.Add(time.Hour).Unix(), "exp": now.Add(2 * time.Hour).Unix()}, false},
		{"nbf an hour ahead", jwt.MapClaims{"sub": "u", "nbf": now.Add(time.Hour).Unix(), "exp": now.Add(2 * time.Hour).Unix()}, false},
		{"iat 20s ahead (skew)", jwt.MapClaims{"sub": "u", "iat": now.Add(20 * time.Second).Unix(), "exp": now.Add(time.Hour).Unix()}, true},
		{"expired 10s ago", jwt.MapClaims{"sub": "u", "exp": now.Add(-10 * time.Second).Unix()}, false},
	}
	for _, c := range cases {
		if err := verifyWith(t, c.claims); (err == nil) != c.ok {
			t.Errorf("%s: ok=%v, err=%v", c.name, c.ok, err)
		}
	}
}

// TestJWTVerifier_AllowNoExpOptOut: JWT_ALLOW_NO_EXP=1 restores the old acceptance.
func TestJWTVerifier_AllowNoExpOptOut(t *testing.T) {
	t.Setenv("JWT_ALLOW_NO_EXP", "1")
	if err := verifyWith(t, jwt.MapClaims{"sub": "u", "iat": time.Now().Unix()}); err != nil {
		t.Fatalf("opt-out set: a token without exp must verify, got %v", err)
	}
}
