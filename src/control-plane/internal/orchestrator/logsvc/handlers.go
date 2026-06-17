package logsvc

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func (s *Service) handleIngest(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Level   string         `json:"level"`
		Source  string         `json:"source"`
		Message string         `json:"message"`
		Data    map[string]any `json:"data"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		shared.WriteJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_body"})
		return
	}
	entry, full := s.add(Entry{
		Level:   orDefault(body.Level, "info"),
		Source:  orDefault(body.Source, "unknown"),
		Message: body.Message,
		Data:    body.Data,
	})
	if full {
		go s.flush()
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"accepted": true, "entry": entry})
}

func (s *Service) handleList(w http.ResponseWriter, r *http.Request) {
	limit := listLimit(r)
	s.mu.Lock()
	n := len(s.entries)
	if limit < n {
		out := make([]Entry, limit)
		copy(out, s.entries[n-limit:]) // last `limit` entries
		s.mu.Unlock()
		shared.WriteJSON(w, http.StatusOK, out)
		return
	}
	out := make([]Entry, n)
	copy(out, s.entries)
	s.mu.Unlock()
	shared.WriteJSON(w, http.StatusOK, out)
}

func listLimit(r *http.Request) int {
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	if limit > maxBufferSize {
		limit = maxBufferSize
	}
	return limit
}
