package emailsvc

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// sendRequest mirrors SendEmailDto.
type sendRequest struct {
	To      string `json:"to"`
	Subject string `json:"subject"`
	HTML    string `json:"html"`
	Text    string `json:"text"`
}

// validate reproduces the DTO constraints: a valid recipient, a non-empty
// subject, and at least one of html/text. The recipient pattern is the same
// pragmatic shape class-validator's @IsEmail accepts for the common case:
// local@domain.tld with no spaces. Kept deliberately permissive — the SMTP
// server is the real authority on deliverability.
func (r sendRequest) validate() error {
	// perf: regex compiled per call — validation path, not hot.
	emailRe := regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)
	if !emailRe.MatchString(r.To) {
		return fmt.Errorf("to must be a valid email")
	}
	if strings.TrimSpace(r.Subject) == "" {
		return fmt.Errorf("subject is required")
	}
	if r.HTML == "" && r.Text == "" {
		return fmt.Errorf("either html or text must be provided")
	}
	return nil
}

func (s *Service) handleSend(w http.ResponseWriter, r *http.Request) {
	var req sendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_body"})
		return
	}
	if err := req.validate(); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	m := &message{
		from:      s.from,
		to:        req.To,
		subject:   req.Subject,
		html:      req.HTML,
		text:      req.Text,
		messageID: newMessageID(s.from),
	}
	if err := s.send(m); err != nil {
		s.log.Error("smtp send failed", "to", req.To, "err", err)
		httpx.WriteJSON(w, http.StatusBadGateway, map[string]any{"error": "send_failed"})
		return
	}
	s.log.Info("email sent", "messageId", m.messageID, "to", req.To)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"messageId": m.messageID})
}
