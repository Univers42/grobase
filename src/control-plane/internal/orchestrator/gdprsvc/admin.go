/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   admin.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:48:26 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:28 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

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
// On a "completed" transition it fires the app erasure webhook, then anonymises
// the user's audit_log rows (so rows written up to the app's delete are caught),
// then marks the request done. An erase error is a 5xx and the status stays as
// it was; both steps are idempotent, so the admin retries (ADR 0022).
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
	if status == "completed" && !s.eraseUser(w, r, req.UserID) {
		return
	}
	updated, err := s.store.updateRequest(r.Context(), id, status, adminID, optional(note))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, updated)
}

// eraseUser fires the app webhook, then anonymises the audit rows; false means
// the erase failed and a 5xx was already written.
func (s *Service) eraseUser(w http.ResponseWriter, r *http.Request, userID string) bool {
	s.doDeletion(r.Context(), userID)
	return !s.fail(w, s.eraseAudit(r.Context(), userID))
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
