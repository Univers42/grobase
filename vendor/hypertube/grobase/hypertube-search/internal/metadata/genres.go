package metadata

import (
	"context"
	"sync"
)

// genreNames resolves TMDb genre ids to names, loading the id→name map once per
// process. The map is memoised on the Enricher via a sync.Once-guarded field;
// no global state (see .claude/rules/no-globals.md).
func (e *Enricher) genreNames(ctx context.Context, ids []int) []string {
	m := e.genres(ctx)
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if n := m[id]; n != "" {
			out = append(out, n)
		}
	}
	return out
}

// genreState lazily holds the loaded id→name map. It lives on the Enricher
// (injected), populated under once.
type genreState struct {
	once sync.Once
	m    map[int]string
}

// genres returns the id→name map, fetching /genre/movie/list on first use.
func (e *Enricher) genres(ctx context.Context) map[int]string {
	e.gstate.once.Do(func() {
		e.gstate.m = e.loadGenres(ctx)
	})
	return e.gstate.m
}

// loadGenres fetches the movie genre list, returning an empty map on any error
// so a failed genre fetch never breaks enrichment.
func (e *Enricher) loadGenres(ctx context.Context) map[int]string {
	var resp struct {
		Genres []struct {
			ID   int    `json:"id"`
			Name string `json:"name"`
		} `json:"genres"`
	}
	m := map[int]string{}
	if err := e.get(ctx, "/genre/movie/list", nil, &resp); err == nil {
		for _, g := range resp.Genres {
			m[g.ID] = g.Name
		}
	}
	return m
}
