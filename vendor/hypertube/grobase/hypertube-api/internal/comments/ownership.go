package comments

import (
	"encoding/json"
	"net/http"

	"hypertube/api/internal/httpx"
	"hypertube/api/internal/oauth"
	"hypertube/api/internal/store"
)

// owns checks that the comment id exists and is authored by the caller, writing
// the exact failure response itself: 404 when absent, 403 when it exists but the
// token subject != author_id. It returns true only when the caller may mutate it.
func (h *Handler) owns(w http.ResponseWriter, r *http.Request, id string) bool {
	row, err := h.find(r.Context(), id)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not read comment")
		return false
	}
	if row == nil {
		httpx.WriteError(w, http.StatusNotFound, "comment not found")
		return false
	}
	if authorOf(row) != oauth.Subject(r.Context()) {
		httpx.WriteError(w, http.StatusForbidden, "not the comment author")
		return false
	}
	return true
}

// authorOf returns the stored author_id of a comment row ("" when missing).
func authorOf(row store.Row) string {
	if id, ok := row["author_id"].(string); ok {
		return id
	}
	return ""
}

// decodeNew reads a new-comment body: content is required, movie_id optional in
// the body (a path movie_id overrides it). Returns ok=false on empty content.
func decodeNew(r *http.Request) (store.Row, bool) {
	var raw struct {
		Content string `json:"content"`
		MovieID string `json:"movie_id"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<16)).Decode(&raw); err != nil || raw.Content == "" {
		return nil, false
	}
	in := store.Row{"content": raw.Content}
	if mid := r.PathValue("movie_id"); mid != "" {
		in["movie_id"] = mid
	} else if raw.MovieID != "" {
		in["movie_id"] = raw.MovieID
	}
	return in, true
}

// decodePatch reads a comment edit: only content is mutable. ok=false on empty.
func decodePatch(r *http.Request) (store.Row, bool) {
	var raw struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<16)).Decode(&raw); err != nil || raw.Content == "" {
		return nil, false
	}
	return store.Row{"content": raw.Content}, true
}
