package tmdb

import (
	"encoding/json"
	"net/http"
)

type server struct{ c *Client }

// NewMux returns the TMDB proxy's GET-only JSON routes bound to c. Kong fronts
// this route with key-auth + CORS, so the proxy itself trusts the gateway.
func NewMux(c *Client) http.Handler {
	s := &server{c: c}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /tmdb/v1/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	mux.HandleFunc("GET /tmdb/v1/search", s.search)
	mux.HandleFunc("GET /tmdb/v1/discover/movie", func(w http.ResponseWriter, r *http.Request) { s.discover(w, r, "movie") })
	mux.HandleFunc("GET /tmdb/v1/discover/tv", func(w http.ResponseWriter, r *http.Request) { s.discover(w, r, "tv") })
	mux.HandleFunc("GET /tmdb/v1/movie/{id}", func(w http.ResponseWriter, r *http.Request) { s.detail(w, r, "movie") })
	mux.HandleFunc("GET /tmdb/v1/tv/{id}", func(w http.ResponseWriter, r *http.Request) { s.detail(w, r, "tv") })
	return mux
}

// writeJSON encodes v as a JSON body with the given status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
