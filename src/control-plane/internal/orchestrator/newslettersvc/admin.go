package newslettersvc

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (s *Service) adminSubscribers(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	limit := queryInt(r, "limit", 100)
	offset := queryInt(r, "offset", 0)
	out, err := s.store.listSubscribers(r.Context(), limit, offset)
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

/* ─────── Campaign (all admin) ─────── */

func (s *Service) campaignSend(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireAdminUser(w, r)
	if !ok {
		return
	}
	var b struct {
		Subject string `json:"subject"`
		HTML    string `json:"html"`
		Text    string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil ||
		strings.TrimSpace(b.Subject) == "" || strings.TrimSpace(b.HTML) == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "subject and html are required")
		return
	}
	sent, failed, err := s.sendCampaign(r.Context(), b.Subject, b.HTML, b.Text, userID)
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"sent": sent, "failed": failed})
}

func (s *Service) campaignHistory(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	out, err := s.store.history(r.Context(), queryInt(r, "limit", 50))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}
