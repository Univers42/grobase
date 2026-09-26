package tenants

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const prevSecret = "the-previous-jwt-secret-still-valid-during-a-rotation"

// signWith signs a live token for subject u-1 with key under method m.
func signWith(t *testing.T, m jwt.SigningMethod, key string) string {
	t.Helper()
	tok := jwt.NewWithClaims(m, jwt.MapClaims{"sub": "u-1", "exp": time.Now().Add(time.Hour).Unix()})
	signed, err := tok.SignedString([]byte(key))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signed
}

// verifierWithPrev builds an HS256 verifier on testSecret with JWT_SECRET_PREV
// set to prev (empty = unset).
func verifierWithPrev(t *testing.T, prev string) *JWTVerifier {
	t.Helper()
	t.Setenv("JWT_SECRET_PREV", prev)
	v, err := NewJWTVerifier(testSecret, "")
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestJWTVerifier_PrevSecret(t *testing.T) {
	cases := []struct {
		name   string
		prev   string
		method jwt.SigningMethod
		key    string
		ok     bool
	}{
		{"current secret, prev set", prevSecret, jwt.SigningMethodHS256, testSecret, true},
		{"prev secret, prev set", prevSecret, jwt.SigningMethodHS256, prevSecret, true},
		{"unrelated secret, prev set", prevSecret, jwt.SigningMethodHS256, "an-unrelated-secret", false},
		{"prev secret, prev unset", "", jwt.SigningMethodHS256, prevSecret, false},
		{"current secret, prev unset", "", jwt.SigningMethodHS256, testSecret, true},
		{"prev equals current", testSecret, jwt.SigningMethodHS256, testSecret, true},
		{"prev secret under HS384", prevSecret, jwt.SigningMethodHS384, prevSecret, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := verifierWithPrev(t, c.prev).Verify(signWith(t, c.method, c.key))
			if (err == nil) != c.ok {
				t.Fatalf("accepted=%v, want %v (err: %v)", err == nil, c.ok, err)
			}
		})
	}
}

func TestJWTVerifier_PrevEqualToCurrentAddsNoKey(t *testing.T) {
	if v := verifierWithPrev(t, testSecret); v.prev != nil {
		t.Fatal("JWT_SECRET_PREV equal to the current secret must not add a second key")
	}
}
