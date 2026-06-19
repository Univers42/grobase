// Package comments serves the /comments resource: a cross-owner feed plus
// owner-only mutation. Ownership is the comment's author_id; the contract requires
// distinguishing 403 (exists, not yours) from 404 (absent) exactly.
package comments

import (
	"context"

	"hypertube/api/internal/store"
)

// commentsTable is the Mongo collection backing comments.
const commentsTable = "comments"

// Handler serves the /comments routes against the Store.
type Handler struct {
	store store.Store
}

// New returns a comments Handler bound to st.
func New(st store.Store) *Handler {
	return &Handler{store: st}
}

// latest reads the newest comments cross-owner (date descending).
func (h *Handler) latest(ctx context.Context) ([]store.Row, error) {
	res, err := h.store.Query(ctx, commentsTable, store.Query{
		Op: "list", Sort: map[string]any{"date": "desc"}, Limit: 50,
	})
	if err != nil {
		return nil, err
	}
	return res.Rows, nil
}

// find returns the single comment row for id, or nil when absent.
func (h *Handler) find(ctx context.Context, id string) (store.Row, error) {
	res, err := h.store.Query(ctx, commentsTable, store.Query{
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
