// Package mediahttp is the HTTP surface of hypertube-media: the net/http mux and
// its handlers. It depends on the other domains only through narrow ports.
package mediahttp

import (
	"context"
	"encoding/json"
	"net/http"

	"hypertube/media/internal/torrent"
)

// Resolver maps a media id to its torrent reference via the Grobase data plane.
type Resolver interface {
	Resolve(ctx context.Context, mediaID string) (ref string, title string, err error)
}

// Engine adds a torrent and returns a streaming handle (the torrent domain port).
type Engine interface {
	Ensure(ctx context.Context, ref string) (*torrent.Handle, error)
}

// JobStore records and reports a movie's download/cache state.
type JobStore interface {
	Save(ctx context.Context, mediaID, title string, p torrent.Progress) error
	Touch(mediaID string) error
}

// Subtitles returns a WebVTT track for a media id and language.
type Subtitles interface {
	VTT(ctx context.Context, mediaID, lang string) string
}

// Deps are the injected collaborators of the HTTP layer (constructed in main).
type Deps struct {
	Enabled   bool
	Resolver  Resolver
	Engine    Engine
	Jobs      JobStore
	Subtitles Subtitles
}

// server binds the injected deps for the handler methods.
type server struct{ d Deps }

// NewMux returns the hypertube-media routes. With d.Enabled false only /health
// answers; every other route returns 503 (the feature flag is OFF).
func NewMux(d Deps) http.Handler {
	s := &server{d: d}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /media/v1/health", health)
	mux.Handle("POST /media/v1/movies/{id}/ensure", s.gate(s.ensure))
	mux.Handle("GET /media/v1/movies/{id}/status", s.gate(s.status))
	mux.Handle("GET /media/v1/movies/{id}/stream", s.gate(s.stream))
	mux.Handle("GET /media/v1/movies/{id}/subtitles/{lang}", s.gate(s.subtitles))
	return mux
}

// health answers the liveness probe regardless of the feature flag.
func health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// gate wraps a handler so it returns 503 when the media feature is disabled.
func (s *server) gate(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.d.Enabled {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "media disabled"})
			return
		}
		h(w, r)
	}
}

// writeJSON encodes v as a JSON body with the given status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
