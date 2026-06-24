package oauth

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
)

// ctxKey is the unexported context-key type for the request subject (avoids
// collisions and keeps the key out of the package's public surface).
type ctxKey struct{}

// RequireBearer wraps next so that every request must carry a valid
// "Authorization: Bearer <token>" header; the verified subject is stashed in the
// request context for downstream handlers. Any failure is a single 401.
func (i *Issuer) RequireBearer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			unauthorized(w)
			return
		}
		sub, err := i.Verify(token)
		if err != nil {
			unauthorized(w)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, sub)))
	})
}

// Subject returns the verified token subject placed on ctx by RequireBearer.
func Subject(ctx context.Context) string {
	sub, _ := ctx.Value(ctxKey{}).(string)
	return sub
}

// bearerToken extracts the token from a "Bearer <token>" Authorization header.
func bearerToken(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return "", false
	}
	return strings.TrimSpace(h[len(prefix):]), true
}

// unauthorized writes the shared 401 problem+json body for any auth failure.
func unauthorized(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/problem+json; charset=utf-8")
	w.WriteHeader(http.StatusUnauthorized)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"type": "about:blank", "title": "invalid or missing bearer token", "status": 401,
	})
}
