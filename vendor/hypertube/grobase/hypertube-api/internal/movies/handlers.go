package movies

import (
	"net/http"

	"hypertube/api/internal/httpx"
	"hypertube/api/internal/store"
)

// List serves GET /movies -> 200 with [{id,name}], popularity-sorted.
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	rows, err := h.listMovies(r.Context())
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not read movies")
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		out = append(out, map[string]any{"id": row["id"], "name": row["name"]})
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// Get serves GET /movies/{id} -> 200 detail with comment_count; 404 if unknown.
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	row, err := h.findMovie(r.Context(), id)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not read movie")
		return
	}
	if row == nil {
		httpx.WriteError(w, http.StatusNotFound, "movie not found")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, detail(row, h.commentCount(r.Context(), id)))
}

// detail projects the contract's movie-detail shape from a stored row plus its
// aggregated comment count.
func detail(row store.Row, count int) map[string]any {
	return map[string]any{
		"id": row["id"], "name": row["name"], "rating": row["rating"],
		"year": row["year"], "length": row["length"],
		"subtitle_langs": row["subtitle_langs"], "comment_count": count,
	}
}

// aggCount reads a count out of an aggregate result, falling back to rowCount or
// the returned row's "count" field across the shapes the data plane may use.
func aggCount(res store.Result) int {
	if res.RowCount > 0 && len(res.Rows) == 0 {
		return res.RowCount
	}
	if len(res.Rows) == 1 {
		if c, ok := res.Rows[0]["count"].(float64); ok {
			return int(c)
		}
	}
	return len(res.Rows)
}
