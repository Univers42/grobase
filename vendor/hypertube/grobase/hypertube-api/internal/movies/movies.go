// Package movies serves the read-only /movies catalog from the movies collection,
// enriching a single movie with its comment count aggregated over comments.
package movies

import (
	"context"

	"hypertube/api/internal/store"
)

// moviesTable and commentsTable are the Mongo collections this package reads.
const (
	moviesTable   = "movies"
	commentsTable = "comments"
)

// Handler serves the /movies routes against the Store.
type Handler struct {
	store store.Store
}

// New returns a movies Handler bound to st.
func New(st store.Store) *Handler {
	return &Handler{store: st}
}

// listMovies reads the catalog sorted by popularity (descending), cross-owner.
func (h *Handler) listMovies(ctx context.Context) ([]store.Row, error) {
	res, err := h.store.Query(ctx, moviesTable, store.Query{
		Op: "list", Sort: map[string]any{"popularity": "desc"}, Limit: 200,
	})
	if err != nil {
		return nil, err
	}
	return res.Rows, nil
}

// findMovie returns the single movie row for id, or nil when absent.
func (h *Handler) findMovie(ctx context.Context, id string) (store.Row, error) {
	res, err := h.store.Query(ctx, moviesTable, store.Query{
		Op: "get", Filter: map[string]any{"id": map[string]any{"$eq": id}}, Limit: 1,
	})
	if err != nil {
		return nil, err
	}
	if len(res.Rows) == 0 {
		return nil, nil
	}
	return res.Rows[0], nil
}

// commentCount aggregates the number of comments whose movie_id == id.
func (h *Handler) commentCount(ctx context.Context, id string) int {
	res, err := h.store.Query(ctx, commentsTable, store.Query{
		Op: "aggregate", Filter: map[string]any{"movie_id": map[string]any{"$eq": id}},
		Data: store.Row{"count": true},
	})
	if err != nil {
		return 0
	}
	return aggCount(res)
}
