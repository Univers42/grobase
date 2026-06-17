package sessionsvc

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

/* ─────── Revocation endpoints (user-scoped + service_role admin) ─────── */

func (s *Service) revoke(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	err := s.store.revoke(r.Context(), r.PathValue("id"), userID)
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"revoked": true})
}

func (s *Service) revokeAll(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	n, err := s.store.revokeAll(r.Context(), userID, bearer(r))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"revoked": n})
}

func (s *Service) adminForceRevoke(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	err := s.store.forceRevoke(r.Context(), r.PathValue("id"))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"revoked": true})
}

func (s *Service) adminForceRevokeAll(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	n, err := s.store.forceRevokeAll(r.Context(), r.PathValue("userId"))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"revoked": n})
}

func (s *Service) adminCleanup(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	n, err := s.store.cleanupExpired(r.Context())
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"deletedCount": n})
}
