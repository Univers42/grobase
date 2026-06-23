package tmdb

import (
	"context"
	"net/url"
	"strconv"
)

// Filters are the optional discover knobs the MovieVerse explorer sends.
type Filters struct {
	Page, Year, Genre, MinVotes int
	MinRating                   float64
	Sort                        string
}

// searchItem is a /search/multi result (a rawItem plus its media_type).
type searchItem struct {
	rawItem
	MediaType string `json:"media_type"`
}

// Search returns poster-bearing movies + series matching query, mapped to Media.
func (c *Client) Search(ctx context.Context, query string) ([]Media, error) {
	if query == "" {
		return []Media{}, nil
	}
	var resp struct {
		Results []searchItem `json:"results"`
	}
	if err := c.get(ctx, "/search/multi", url.Values{"query": {query}, "page": {"1"}}, &resp); err != nil {
		return nil, err
	}
	out := make([]Media, 0, len(resp.Results))
	for _, r := range resp.Results {
		if r.MediaType != "movie" && r.MediaType != "tv" {
			continue
		}
		if m := mapItem(r.rawItem, mediaType(r.MediaType), c.genres.forKind(ctx, r.MediaType)); m.PosterPath != "" {
			out = append(out, m)
		}
	}
	return out, nil
}

// Discover lists movies (kind "movie") or series ("tv") under the given filters.
func (c *Client) Discover(ctx context.Context, kind string, f Filters) ([]Media, error) {
	var resp struct {
		Results []rawItem `json:"results"`
	}
	if err := c.get(ctx, "/discover/"+kind, discoverParams(kind, f), &resp); err != nil {
		return nil, err
	}
	gmap := c.genres.forKind(ctx, kind)
	out := make([]Media, 0, len(resp.Results))
	for _, r := range resp.Results {
		if m := mapItem(r, mediaType(kind), gmap); m.PosterPath != "" {
			out = append(out, m)
		}
	}
	return out, nil
}

// mediaType maps a TMDB kind ("movie"/"tv") to the MovieVerse enum.
func mediaType(kind string) string {
	if kind == "tv" {
		return "SERIE"
	}
	return "MOVIE"
}

// discoverParams renders the TMDB /discover query for kind under f (region ES;
// the year param name differs for tv vs movie).
func discoverParams(kind string, f Filters) url.Values {
	p := url.Values{"region": {region}, "include_adult": {"false"}}
	p.Set("page", strconv.Itoa(max(f.Page, 1)))
	p.Set("sort_by", orDefault(f.Sort, "popularity.desc"))
	if f.Genre > 0 {
		p.Set("with_genres", strconv.Itoa(f.Genre))
	}
	if f.MinRating > 0 {
		p.Set("vote_average.gte", strconv.FormatFloat(f.MinRating, 'f', -1, 64))
	}
	if f.MinVotes > 0 {
		p.Set("vote_count.gte", strconv.Itoa(f.MinVotes))
	}
	if f.Year > 0 {
		key := "primary_release_year"
		if kind == "tv" {
			key = "first_air_date_year"
		}
		p.Set(key, strconv.Itoa(f.Year))
	}
	return p
}

// orDefault returns v, or def when v is empty.
func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}
