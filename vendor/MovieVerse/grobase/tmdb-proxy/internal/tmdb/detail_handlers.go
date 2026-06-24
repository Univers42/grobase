package tmdb

import (
	"net/http"
	"strconv"
)

// detail handles GET /tmdb/v1/{movie,tv}/{id}: a bad id → 400, an upstream
// failure → 502 (no internal detail leaked, per .claude/rules/api-convention.md).
func (s *server) detail(w http.ResponseWriter, r *http.Request, kind string) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil || id <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
		return
	}
	m, err := s.c.Detail(r.Context(), kind, id)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "upstream unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, m)
}
