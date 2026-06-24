package comments

import (
	"net/http"
	"time"

	"hypertube/api/internal/httpx"
	"hypertube/api/internal/oauth"
	"hypertube/api/internal/store"
)

// Create serves POST /comments and POST /movies/{movie_id}/comments -> 201. The
// server fills author_id/author_username from the token subject and stamps date;
// the client supplies only content (+ movie_id, from path or body).
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	in, ok := decodeNew(r)
	if !ok {
		httpx.WriteError(w, http.StatusBadRequest, "missing or invalid content")
		return
	}
	sub := oauth.Subject(r.Context())
	in["author_id"] = sub
	in["author_username"] = sub
	in["date"] = time.Now().UTC().Format(time.RFC3339)
	h.insert(w, r, in)
}

// insert writes the new comment row and reports 201 with the created body.
func (h *Handler) insert(w http.ResponseWriter, r *http.Request, in store.Row) {
	res, err := h.store.Query(r.Context(), commentsTable, store.Query{Op: "insert", Data: in})
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not create comment")
		return
	}
	body := in
	if len(res.Rows) == 1 {
		body = res.Rows[0]
	}
	httpx.WriteJSON(w, http.StatusCreated, public(body))
}

// Patch serves PATCH /comments/{id}: owner-only edit. 404 when absent, 403 when
// it exists but the caller is not the author, 400 on an invalid body, 200 on ok.
func (h *Handler) Patch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !h.owns(w, r, id) {
		return
	}
	patch, ok := decodePatch(r)
	if !ok {
		httpx.WriteError(w, http.StatusBadRequest, "invalid comment fields")
		return
	}
	if _, err := h.store.Query(r.Context(), commentsTable, store.Query{
		Op: "update", Data: patch, Filter: map[string]any{"id": map[string]any{"$eq": id}},
	}); err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not update comment")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"id": id, "updated": true})
}

// Delete serves DELETE /comments/{id} -> 204 owner-only; 404 absent, 403 not yours.
func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !h.owns(w, r, id) {
		return
	}
	if _, err := h.store.Query(r.Context(), commentsTable, store.Query{
		Op: "delete", Filter: map[string]any{"id": map[string]any{"$eq": id}},
	}); err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not delete comment")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
