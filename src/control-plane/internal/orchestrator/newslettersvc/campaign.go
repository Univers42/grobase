package newslettersvc

import (
	"context"
	"strings"
)

// sendCampaign fans the campaign out to every confirmed subscriber and records
// the send. Recipients are sent in batches of batchSize (parity with the Node
// Promise.allSettled batching); a non-2xx or transport error counts as failed.
func (s *Service) sendCampaign(ctx context.Context, subject, html, text, sentBy string) (int, int, error) {
	recipients, err := s.store.confirmedEmails(ctx)
	if err != nil {
		return 0, 0, err
	}
	if len(recipients) == 0 {
		s.log.Warn("no confirmed subscribers — skipping campaign send")
		return 0, 0, nil
	}
	sent, failed := s.fanOut(ctx, recipients, subject, html, text)
	if err := s.store.logSend(ctx, subject, sent, optional(sentBy)); err != nil {
		return sent, failed, err
	}
	s.log.Info("campaign sent", "subject", subject, "sent", sent, "failed", failed)
	return sent, failed, nil
}

// fanOut sends the campaign to every recipient in batches of batchSize (parity
// with the Node Promise.allSettled batching) and returns (sent, failed).
func (s *Service) fanOut(ctx context.Context, recipients []Recipient,
	subject, html, text string,
) (sent, failed int) {
	for i := 0; i < len(recipients); i += s.batchSize {
		end := i + s.batchSize
		if end > len(recipients) {
			end = len(recipients)
		}
		for _, rcpt := range recipients[i:end] {
			if err := s.send(ctx, rcpt.Email, subject, html, text); err != nil {
				failed++
			} else {
				sent++
			}
		}
	}
	return sent, failed
}

// notifyConfirmation fires the confirmation email; failures are logged and
// swallowed (parity with the Node try/catch — subscribe still succeeds).
func (s *Service) notifyConfirmation(ctx context.Context, email, firstName, token string) {
	greeting := ""
	if firstName != "" {
		greeting = " " + firstName
	}
	confirmURL := strings.TrimRight(s.baseURL, "/") + "/confirm/" + token
	html := "<p>Hello" + greeting + ",</p>\n" +
		"<p>Please confirm your subscription by clicking the link below:</p>\n" +
		`<p><a href="` + confirmURL + `">Confirm subscription</a></p>` + "\n" +
		"<p>If you did not subscribe, you can safely ignore this email.</p>"
	if err := s.send(ctx, email, "Confirm your newsletter subscription", html, ""); err != nil {
		s.log.Error("failed to send confirmation email", "err", err)
	}
}
