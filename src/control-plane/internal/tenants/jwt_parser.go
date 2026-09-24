package tenants

import (
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// jwtClockSkew is the leeway on iat/nbf (and the library's exp check; validateClaims
// re-checks exp with none).
const jwtClockSkew = 60 * time.Second

// newJWTParser builds the one parser a verifier reuses: pinned to alg, refusing an
// iat/nbf later than now+skew, and requiring exp (M-3: a token without one never
// expires) unless JWT_ALLOW_NO_EXP=1 opts back into the old behaviour.
func newJWTParser(alg string) *jwt.Parser {
	opts := []jwt.ParserOption{
		jwt.WithValidMethods([]string{alg}),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(jwtClockSkew),
	}
	if v := strings.TrimSpace(os.Getenv("JWT_ALLOW_NO_EXP")); v != "1" && !strings.EqualFold(v, "true") {
		opts = append(opts, jwt.WithExpirationRequired())
	}
	return jwt.NewParser(opts...)
}
