package tmdb

import (
	"net/http"
	"strconv"
)

// search handles GET /tmdb/v1/search?query=; on upstream error it degrades to []
// (like the dropped TmdbService) so the UI never hard-fails.
func (s *server) search(w http.ResponseWriter, r *http.Request) {
	res, err := s.c.Search(r.Context(), r.URL.Query().Get("query"))
	if err != nil {
		writeJSON(w, http.StatusOK, []Media{})
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// discover handles GET /tmdb/v1/discover/{movie,tv}; degrades to [] on error.
func (s *server) discover(w http.ResponseWriter, r *http.Request, kind string) {
	res, err := s.c.Discover(r.Context(), kind, filtersFrom(r))
	if err != nil {
		writeJSON(w, http.StatusOK, []Media{})
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// filtersFrom reads the explorer's query params into Filters (0/"" = unset).
func filtersFrom(r *http.Request) Filters {
	q := r.URL.Query()
	atoi := func(k string) int { n, _ := strconv.Atoi(q.Get(k)); return n }
	rating, _ := strconv.ParseFloat(q.Get("minRating"), 64)
	return Filters{
		Page: atoi("page"), Year: atoi("year"), Genre: atoi("genre"),
		MinVotes: atoi("minVotes"), MinRating: rating, Sort: q.Get("sort"),
	}
}
