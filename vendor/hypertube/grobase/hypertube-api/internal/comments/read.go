package comments

import (
	"net/http"

	"hypertube/api/internal/httpx"
	"hypertube/api/internal/store"
)

// List serves GET /comments -> 200 latest [{id,author_username,date,content}].
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	rows, err := h.latest(r.Context())
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not read comments")
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		out = append(out, public(row))
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// Get serves GET /comments/{id} -> 200 the comment; 404 when absent.
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	row, err := h.find(r.Context(), r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not read comment")
		return
	}
	if row == nil {
		httpx.WriteError(w, http.StatusNotFound, "comment not found")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, public(row))
}

// public projects the safe, caller-facing comment shape (no author_id leak).
func public(row store.Row) map[string]any {
	return map[string]any{
		"id": row["id"], "author_username": row["author_username"],
		"date": row["date"], "content": row["content"],
	}
}
