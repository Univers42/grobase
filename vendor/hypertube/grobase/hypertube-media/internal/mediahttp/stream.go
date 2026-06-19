package mediahttp

import (
	"net/http"
	"strings"

	"hypertube/media/internal/stream"
	"hypertube/media/internal/torrent"
	"hypertube/media/internal/transcode"
)

// stream handles GET /media/v1/movies/{id}/stream: it resolves and ensures the
// torrent, then range-serves a browser-native container (206) or transcodes a
// non-native one to fragmented mp4 (200). Watching it bumps the cache mtime.
func (s *server) stream(w http.ResponseWriter, r *http.Request) {
	h, ok := s.ensureHandle(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	_ = s.d.Jobs.Touch(id)
	rs := h.ReadSeeker()
	if transcode.Native(h.Name()) {
		stream.Serve(w, r, rs, h.Length(), "video/mp4")
		return
	}
	transcode.Serve(w, r, rs)
}

// subtitles handles GET /media/v1/movies/{id}/subtitles/{lang}.vtt: it returns a
// WebVTT track (empty but valid when no key/track is available).
func (s *server) subtitles(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	lang := strings.TrimSuffix(r.PathValue("lang"), ".vtt")
	vtt := s.d.Subtitles.VTT(r.Context(), id, lang)
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(vtt))
}

// ensureHandle resolves the movie and ensures its torrent, writing the error
// response itself; ok is false when the caller must stop.
func (s *server) ensureHandle(w http.ResponseWriter, r *http.Request) (*torrent.Handle, bool) {
	id := r.PathValue("id")
	ref, _, err := s.d.Resolver.Resolve(r.Context(), id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return nil, false
	}
	h, err := s.d.Engine.Ensure(r.Context(), ref)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return nil, false
	}
	return h, true
}
