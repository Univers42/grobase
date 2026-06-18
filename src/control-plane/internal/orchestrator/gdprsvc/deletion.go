package gdprsvc

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (s *Service) withdrawNonEssential(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	n, err := s.store.withdrawNonEssential(r.Context(), userID)
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"updated": n})
}

/* ─────── export ─────── */

func (s *Service) export(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	appData := s.doExport(r.Context(), userID)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"exportedAt":    time.Now().UTC().Format(time.RFC3339Nano),
		"formatVersion": "1.0",
		"userId":        userID,
		"data":          appData,
	})
}

/* ─────── deletion ─────── */

func (s *Service) createDeletion(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	var b struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(r.Body).Decode(&b)
	exists, err := s.store.pendingExists(r.Context(), userID)
	if s.fail(w, err) {
		return
	}
	if exists {
		httpx.WriteError(w, http.StatusConflict, "conflict", "A pending data deletion request already exists")
		return
	}
	d, err := s.store.createDeletion(r.Context(), userID, optional(b.Reason))
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, d)
}

func (s *Service) myDeletion(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	d, err := s.store.myRequest(r.Context(), userID)
	if s.fail(w, err) {
		return
	}
	if d == nil {
		httpx.WriteJSON(w, http.StatusOK, nil)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, d)
}

func (s *Service) cancelDeletion(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	d, err := s.store.cancelRequest(r.Context(), userID)
	if errors.Is(err, errNotFound) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "No pending deletion request found")
		return
	}
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, d)
}
