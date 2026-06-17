package shared

import (
	"net/http"
	"strings"
)

// cutBearer returns the token after a case-insensitive "Bearer " scheme prefix,
// and whether the prefix was present.
func cutBearer(auth string) (string, bool) {
	const p = "bearer "
	if len(auth) >= len(p) && strings.EqualFold(auth[:len(p)], p) {
		return strings.TrimSpace(auth[len(p):]), true
	}
	return "", false
}

// APIKeyFromRequest extracts a control-plane API key from a request: the
// X-API-Key header wins; otherwise an "Authorization: Bearer <key>" header is
// accepted only when the bearer value is an mbk_-prefixed API key (so a JWT in
// the same header is ignored). Returns "" when no key is present.
func APIKeyFromRequest(r *http.Request) string {
	if k := strings.TrimSpace(r.Header.Get("X-API-Key")); k != "" {
		return k
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if rest, ok := cutBearer(auth); ok && strings.HasPrefix(rest, "mbk_") {
		return rest
	}
	return ""
}
