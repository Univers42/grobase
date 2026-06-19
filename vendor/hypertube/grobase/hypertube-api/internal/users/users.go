// Package users serves the /users resource: a cross-owner directory read from the
// profiles collection, with email exposed only to the profile's own owner.
package users

import (
	"context"

	"hypertube/api/internal/store"
)

// profilesTable is the Mongo collection backing user profiles.
const profilesTable = "profiles"

// Handler serves the /users routes against the Store.
type Handler struct {
	store store.Store
}

// New returns a users Handler bound to st.
func New(st store.Store) *Handler {
	return &Handler{store: st}
}

// listProfiles reads the directory (id + username) cross-owner, newest first.
func (h *Handler) listProfiles(ctx context.Context) ([]store.Row, error) {
	res, err := h.store.Query(ctx, profilesTable, store.Query{Op: "list", Limit: 200})
	if err != nil {
		return nil, err
	}
	return res.Rows, nil
}

// findProfile returns the single profile row for id, or nil when absent.
func (h *Handler) findProfile(ctx context.Context, id string) (store.Row, error) {
	res, err := h.store.Query(ctx, profilesTable, store.Query{
		Op: "get", Filter: map[string]any{"user_id": map[string]any{"$eq": id}}, Limit: 1,
	})
	if err != nil {
		return nil, err
	}
	if len(res.Rows) == 0 {
		return nil, nil
	}
	return res.Rows[0], nil
}
