package sessionsvc

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

/* ─────── Admin read endpoints (require service_role) ─────── */

func (s *Service) adminAll(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	out, err := s.store.activeSessions(r.Context(), r.URL.Query().Get("userId"))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (s *Service) adminStats(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	st, err := s.store.stats(r.Context())
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, st)
}
