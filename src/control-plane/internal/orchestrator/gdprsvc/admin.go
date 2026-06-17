package gdprsvc

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (s *Service) adminListDeletions(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	out, err := s.store.allRequests(r.Context(), r.URL.Query().Get("status"))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// adminProcessDeletion advances a deletion request to the admin-chosen status.
// On a "completed" transition it fires the app erasure webhook BEFORE marking
// the request done (parity with the Node ordering).
func (s *Service) adminProcessDeletion(w http.ResponseWriter, r *http.Request) {
	adminID, ok := requireAdminUser(w, r)
	if !ok {
		return
	}
	status, note, ok := decodeProcess(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	req, ok := s.loadProcessable(w, r, id)
	if !ok {
		return
	}
	if status == "completed" {
		s.doDeletion(r.Context(), req.UserID)
	}
	updated, err := s.store.updateRequest(r.Context(), id, status, adminID, optional(note))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, updated)
}

// decodeProcess parses the admin process body, validating the status; ok==false
// means a 400 was already written.
func decodeProcess(w http.ResponseWriter, r *http.Request) (status, note string, ok bool) {
	var b struct {
		Status    string `json:"status"`
		AdminNote string `json:"admin_note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || !validStatus(b.Status) {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error",
			"status must be one of in_progress, completed, rejected")
		return "", "", false
	}
	return b.Status, b.AdminNote, true
}

// loadProcessable fetches the deletion request and rejects missing/completed
// ones, writing the response; ok==false means a response was already written.
func (s *Service) loadProcessable(w http.ResponseWriter, r *http.Request, id string) (*DeletionRequest, bool) {
	req, err := s.store.getRequest(r.Context(), id)
	if errors.Is(err, errNotFound) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "Deletion request not found")
		return nil, false
	}
	if s.fail(w, err) {
		return nil, false
	}
	if req.Status == "completed" {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "Request already completed")
		return nil, false
	}
	return req, true
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
