package tenants

import (
	"errors"
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

// RequireIssuer refuses an empty issuer for the user-JWT verifier (M-5): with no
// issuer to compare, any HS256 token minted with the shared secret for another
// purpose — a cross-app realtime token whose sub is a tenant slug, a seed script's
// app token — verifies as a user session. JWT_ALLOW_NO_ISSUER=1 opts out.
func RequireIssuer(issuer string) error {
	if strings.TrimSpace(issuer) != "" {
		return nil
	}
	if v := strings.TrimSpace(os.Getenv("JWT_ALLOW_NO_ISSUER")); v == "1" || strings.EqualFold(v, "true") {
		return nil
	}
	return errors.New("GOTRUE_JWT_ISSUER is empty: set it (compose defaults it to API_EXTERNAL_URL) or JWT_ALLOW_NO_ISSUER=1 to run without issuer verification")
}
