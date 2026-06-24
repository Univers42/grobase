package users

import (
	"net/http"

	"hypertube/api/internal/httpx"
	"hypertube/api/internal/oauth"
	"hypertube/api/internal/store"
)

// List serves GET /users -> 200 with [{id,username}], read cross-owner.
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	rows, err := h.listProfiles(r.Context())
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not read users")
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		out = append(out, map[string]any{"id": row["user_id"], "username": row["username"]})
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// Get serves GET /users/{id} -> 200 public profile; email is added only when the
// token subject equals id; 404 when the profile is unknown.
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	row, err := h.findProfile(r.Context(), id)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not read user")
		return
	}
	if row == nil {
		httpx.WriteError(w, http.StatusNotFound, "user not found")
		return
	}
	if oauth.Subject(r.Context()) == id {
		h.attachEmail(r, row, id)
	}
	httpx.WriteJSON(w, http.StatusOK, row)
}

// Patch serves PATCH /users/{id} -> updates the caller's own profile only; 403
// for someone else's id, 400 on an empty/invalid body, 200 on success.
func (h *Handler) Patch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if oauth.Subject(r.Context()) != id {
		httpx.WriteError(w, http.StatusForbidden, "cannot edit another user's profile")
		return
	}
	patch, ok := decodePatch(r)
	if !ok {
		httpx.WriteError(w, http.StatusBadRequest, "invalid profile fields")
		return
	}
	h.applyPatch(w, r, id, patch)
}

// applyPatch writes the validated patch to the profile and reports the result.
func (h *Handler) applyPatch(w http.ResponseWriter, r *http.Request, id string, patch store.Row) {
	_, err := h.store.Query(r.Context(), profilesTable, store.Query{
		Op: "update", Data: patch, Filter: map[string]any{"user_id": map[string]any{"$eq": id}},
	})
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "could not update profile")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"id": id, "updated": true})
}

// attachEmail enriches the owner's own profile with the GoTrue admin email
// (best-effort: a lookup failure simply omits the field, never errors the read).
func (h *Handler) attachEmail(r *http.Request, row store.Row, id string) {
	if email, err := h.store.AdminEmail(r.Context(), id); err == nil && email != "" {
		row["email"] = email
	}
}
