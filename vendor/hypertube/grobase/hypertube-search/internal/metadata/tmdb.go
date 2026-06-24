package metadata

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	tmdbBase   = "https://api.themoviedb.org/3"
	posterBase = "https://image.tmdb.org/t/p/w500"
)

// Enricher resolves a (title, year) to TMDb metadata using a v4 bearer token (or
// a v3 api key). It is safe with an empty key: Enrich then returns a zero Info,
// so the catalog degrades gracefully instead of failing.
type Enricher struct {
	key    string
	bearer bool
	http   *http.Client
	gstate *genreState
}

// New returns an Enricher bound to the given TMDb credential. A v4 token (a JWT —
// contains dots) goes in the Authorization header; a v3 key (hex) is a query
// param. An empty key disables enrichment (Enrich returns zero Info).
func New(key string) *Enricher {
	return &Enricher{
		key:    key,
		bearer: strings.Contains(key, "."),
		http:   &http.Client{Timeout: 8 * time.Second},
		gstate: &genreState{},
	}
}

// Enrich looks up title/year and returns its rating, genres, summary, cast and
// cover. A missing key, no match, or any upstream error yields a zero Info.
func (e *Enricher) Enrich(ctx context.Context, title string, year int) Info {
	if e.key == "" || title == "" {
		return Info{}
	}
	id, base := e.find(ctx, title, year)
	if id == 0 {
		return Info{}
	}
	base.Cast = e.credits(ctx, id)
	return base
}

// find searches /search/movie and returns the top match's id plus the Info
// derivable from the search row (rating, summary, genre ids resolved, cover).
func (e *Enricher) find(ctx context.Context, title string, year int) (int, Info) {
	p := url.Values{"query": {title}}
	if year > 0 {
		p.Set("year", strconv.Itoa(year))
	}
	var resp struct {
		Results []struct {
			ID       int     `json:"id"`
			Overview string  `json:"overview"`
			Vote     float64 `json:"vote_average"`
			Poster   string  `json:"poster_path"`
			GenreIDs []int   `json:"genre_ids"`
		} `json:"results"`
	}
	if err := e.get(ctx, "/search/movie", p, &resp); err != nil || len(resp.Results) == 0 {
		return 0, Info{}
	}
	r := resp.Results[0]
	return r.ID, Info{
		Rating:  r.Vote,
		Summary: r.Overview,
		Genres:  e.genreNames(ctx, r.GenreIDs),
		Cover:   poster(r.Poster),
	}
}

// credits fetches /movie/{id}/credits and returns the top-billed cast members.
func (e *Enricher) credits(ctx context.Context, id int) []Member {
	var resp struct {
		Cast []struct {
			Name      string `json:"name"`
			Character string `json:"character"`
		} `json:"cast"`
	}
	if err := e.get(ctx, "/movie/"+strconv.Itoa(id)+"/credits", nil, &resp); err != nil {
		return nil
	}
	out := make([]Member, 0, min(len(resp.Cast), 10))
	for i, c := range resp.Cast {
		if i >= 10 {
			break
		}
		out = append(out, Member{Role: c.Character, Name: c.Name})
	}
	return out
}

// poster absolutises a TMDb relative poster path ("" stays "").
func poster(path string) string {
	if path == "" {
		return ""
	}
	return posterBase + path
}

// get issues GET tmdbBase+path with the credential + params, decoding into out.
func (e *Enricher) get(ctx context.Context, path string, params url.Values, out any) error {
	if params == nil {
		params = url.Values{}
	}
	if !e.bearer {
		params.Set("api_key", e.key)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, tmdbBase+path+"?"+params.Encode(), nil)
	if err != nil {
		return err
	}
	if e.bearer {
		req.Header.Set("Authorization", "Bearer "+e.key)
	}
	res, err := e.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return statusError(res.StatusCode)
	}
	return json.NewDecoder(res.Body).Decode(out)
}
