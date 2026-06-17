package sessionsvc

import (
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// fail maps store errors to HTTP status (404/403/500). Returns true if it wrote
// a response (caller should stop).
func (s *Service) fail(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, errNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "session not found")
	case errors.Is(err, errForbidden):
		httpx.WriteError(w, http.StatusForbidden, "forbidden", "not your session")
	default:
		s.log.Error("session store error", "err", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "unexpected error")
	}
	return true
}

// requireUser extracts the verified user id (gateway-injected signed-envelope
// header, legacy header in compat mode).
func requireUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-User-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "missing verified identity")
	return "", false
}

// requireAdmin enforces the service_role gate (parity with RolesGuard).
func requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	if _, ok := requireUser(w, r); !ok {
		return false
	}
	if r.Header.Get("X-Baas-Role") != "service_role" {
		httpx.WriteError(w, http.StatusForbidden, "forbidden", "requires one of: service_role")
		return false
	}
	return true
}

// bearer pulls the raw token out of an Authorization: Bearer <token> header.
func bearer(r *http.Request) string {
	return strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
}
