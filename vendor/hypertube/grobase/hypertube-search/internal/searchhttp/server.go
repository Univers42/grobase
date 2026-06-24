package searchhttp

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
)

// query holds the parsed /search facets.
type query struct {
	text  string
	page  int
	genre string
	year  int
}

type server struct{ svc *Service }

// NewMux returns the search service's GET-only JSON routes. Kong fronts these
// with CORS + key-auth, so the service trusts the gateway.
func NewMux(svc *Service) http.Handler {
	s := &server{svc: svc}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /search/v1/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	mux.HandleFunc("GET /search/v1/search", s.search)
	mux.HandleFunc("GET /search/v1/popular", s.popular)
	return mux
}

// search handles GET /search/v1/search?q=&page=&sort=&genre=&year=, returning a
// paginated, metadata-enriched thumbnail page (name-sorted when q is present).
func (s *server) search(w http.ResponseWriter, r *http.Request) {
	q := parseQuery(r)
	items := s.svc.collect(r.Context(), q.text, q.page)
	writeJSON(w, http.StatusOK, rankAndPage(items, q))
}

// popular handles GET /search/v1/popular, the default view sorted by popularity
// (downloads+peers+seeders) with no text query.
func (s *server) popular(w http.ResponseWriter, r *http.Request) {
	q := parseQuery(r)
	q.text = ""
	items := s.svc.collect(r.Context(), "", q.page)
	writeJSON(w, http.StatusOK, rankAndPage(items, q))
}

// parseQuery reads the facet params (0/"" = unset).
func parseQuery(r *http.Request) query {
	v := r.URL.Query()
	page, _ := strconv.Atoi(v.Get("page"))
	year, _ := strconv.Atoi(v.Get("year"))
	return query{
		text:  strings.TrimSpace(v.Get("q")),
		page:  page,
		genre: strings.TrimSpace(v.Get("genre")),
		year:  year,
	}
}

// writeJSON encodes v as a JSON body with the given status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
