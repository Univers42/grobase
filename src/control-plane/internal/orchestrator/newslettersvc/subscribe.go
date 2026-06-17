package newslettersvc

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

/* ─────── Subscription ─────── */

func (s *Service) subscribe(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Email     string `json:"email"`
		FirstName string `json:"firstName"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || !validEmail(b.Email) {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "a valid email is required")
		return
	}
	ctx := r.Context()
	id, active, existingFirst, found, err := s.store.existing(ctx, b.Email)
	if s.fail(w, err) {
		return
	}
	if found {
		s.reactivateExisting(w, r, b.Email, b.FirstName, existingFirst, id, active)
		return
	}
	s.subscribeNew(w, r, b.Email, b.FirstName)
}

// reactivateExisting handles the found-subscriber branch of subscribe: an active
// row conflicts, an inactive one is reactivated with a fresh token + confirmation.
func (s *Service) reactivateExisting(w http.ResponseWriter, r *http.Request,
	email, firstName string, existingFirst *string, id int64, active bool) {
	if active {
		httpx.WriteError(w, http.StatusConflict, "conflict", "This email is already subscribed")
		return
	}
	ctx := r.Context()
	token := newToken()
	sub, err := s.store.reactivate(ctx, id, token, optional(firstName))
	if s.fail(w, err) {
		return
	}
	s.notifyConfirmation(ctx, email, firstOr(firstName, existingFirst), token)
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"reactivated": true, "subscriber": sub})
}

// subscribeNew inserts a brand-new subscriber and sends the confirmation email.
func (s *Service) subscribeNew(w http.ResponseWriter, r *http.Request, email, firstName string) {
	ctx := r.Context()
	token := newToken()
	sub, err := s.store.insert(ctx, email, optional(firstName), token)
	if s.fail(w, err) {
		return
	}
	s.notifyConfirmation(ctx, email, firstName, token)
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"subscribed": true, "subscriber": sub})
}

func (s *Service) confirm(w http.ResponseWriter, r *http.Request) {
	ok, err := s.store.confirm(r.Context(), r.PathValue("token"))
	if s.fail(w, err) {
		return
	}
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "Invalid or already-used token")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"confirmed": true})
}

func (s *Service) unsubscribe(w http.ResponseWriter, r *http.Request) {
	ok, err := s.store.unsubscribe(r.Context(), r.PathValue("token"))
	if s.fail(w, err) {
		return
	}
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "Invalid token")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"unsubscribed": true})
}
