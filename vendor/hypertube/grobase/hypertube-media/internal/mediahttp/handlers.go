package mediahttp

import (
	"net/http"
)

// ensure handles POST /media/v1/movies/{id}/ensure: it resolves the movie's
// torrent ref, kicks off (or rejoins) the download, records the job, and returns
// 202 with the current progress so the client can poll /status.
func (s *server) ensure(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	ref, title, err := s.d.Resolver.Resolve(r.Context(), id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	h, err := s.d.Engine.Ensure(r.Context(), ref)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	p := h.Progress()
	_ = s.d.Jobs.Save(r.Context(), id, title, p)
	writeJSON(w, http.StatusAccepted, map[string]any{"media_id": id, "progress": p})
}

// status handles GET /media/v1/movies/{id}/status: it returns the live download
// progress (bytes done/total, seeders, ready) for the polling client.
func (s *server) status(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	ref, _, err := s.d.Resolver.Resolve(r.Context(), id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	h, err := s.d.Engine.Ensure(r.Context(), ref)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"media_id": id, "progress": h.Progress()})
}
