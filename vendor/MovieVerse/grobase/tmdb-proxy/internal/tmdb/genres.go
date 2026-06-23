package tmdb

import (
	"context"
	"sync"
)

// genreCache lazily loads + memoises TMDB's movie/tv genre id→name maps so list
// items (which carry only genre_ids) can be labelled. Bound to a Client; no
// global state (see .claude/rules/no-globals.md).
type genreCache struct {
	client *Client
	mu     sync.Mutex
	maps   map[string]map[int]string
}

// newGenreCache returns an empty cache bound to c.
func newGenreCache(c *Client) *genreCache {
	return &genreCache{client: c, maps: map[string]map[int]string{}}
}

// forKind returns the id→name map for "movie"/"tv", loading it once on first use.
func (g *genreCache) forKind(ctx context.Context, kind string) map[int]string {
	g.mu.Lock()
	defer g.mu.Unlock()
	if m, ok := g.maps[kind]; ok {
		return m
	}
	// ponytail: lock held over the one-time genre fetch — warms once per kind per
	// process; swap for a per-kind sync.Once if cold-start contention matters.
	m := g.load(ctx, kind)
	g.maps[kind] = m
	return m
}

// load fetches /genre/{kind}/list, returning an id→name map (empty on error so a
// failed genre fetch never breaks catalog responses).
func (g *genreCache) load(ctx context.Context, kind string) map[int]string {
	var resp struct {
		Genres []idName `json:"genres"`
	}
	m := map[int]string{}
	if err := g.client.get(ctx, "/genre/"+kind+"/list", nil, &resp); err == nil {
		for _, x := range resp.Genres {
			m[x.ID] = x.Name
		}
	}
	return m
}
