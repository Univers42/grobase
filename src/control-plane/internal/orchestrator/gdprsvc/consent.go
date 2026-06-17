package gdprsvc

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

/* ─────── consent ─────── */

func (s *Service) listConsents(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	out, err := s.store.userConsents(r.Context(), userID)
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (s *Service) getConsent(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	c, err := s.store.userConsent(r.Context(), userID, r.PathValue("type"))
	if s.fail(w, err) {
		return
	}
	if c == nil {
		httpx.WriteJSON(w, http.StatusOK, nil) // parity: Node returns null
		return
	}
	httpx.WriteJSON(w, http.StatusOK, c)
}

func (s *Service) setConsent(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	var b struct {
		ConsentType string `json:"consent_type"`
		Consented   *bool  `json:"consented"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || b.ConsentType == "" || b.Consented == nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "consent_type and consented are required")
		return
	}
	c, err := s.store.setConsent(r.Context(), userID, b.ConsentType, *b.Consented)
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, c)
}

func (s *Service) updateConsent(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	var b struct {
		Consented *bool `json:"consented"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || b.Consented == nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "consented is required")
		return
	}
	ctype := r.PathValue("type")
	if !s.consentExists(w, r, userID, ctype) {
		return
	}
	c, err := s.store.updateConsent(r.Context(), userID, ctype, *b.Consented)
	if s.fail(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, c)
}

// consentExists writes a 404/500 and returns false when the consent is missing
// or the lookup fails; true means the caller may proceed.
func (s *Service) consentExists(w http.ResponseWriter, r *http.Request, userID, ctype string) bool {
	existing, err := s.store.userConsent(r.Context(), userID, ctype)
	if s.fail(w, err) {
		return false
	}
	if existing == nil {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "Consent not found")
		return false
	}
	return true
}
