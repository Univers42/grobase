package github

import (
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// session.go — the `auth login --github` identity bridge. A GitHub user maps to a
// DETERMINISTIC GoTrue subject (uuid5 of the github user id), and we mint a short
// HS256 session JWT the existing tenant JWTVerifier accepts. The GitHub OAuth token
// is used once (to read /user) and discarded — never persisted.

// githubSubject derives the stable GoTrue subject for a GitHub user id (deterministic
// across logins, derived only from GitHub's identity — never client input).
func githubSubject(githubUserID int64) string {
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte("github-user:"+strconv.FormatInt(githubUserID, 10))).String()
}

// mintSession mints a GoTrue-shaped HS256 session JWT for `subject`, valid one hour.
func (s *Service) mintSession(subject string) (string, error) {
	now := s.now()
	claims := jwt.MapClaims{
		"sub":  subject,
		"role": "authenticated",
		"aud":  "authenticated",
		"iat":  now.Unix(),
		"exp":  now.Add(time.Hour).Unix(),
	}
	if s.cfg.JWTIssuer != "" {
		claims["iss"] = s.cfg.JWTIssuer
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return tok.SignedString(s.cfg.JWTSecret)
}
