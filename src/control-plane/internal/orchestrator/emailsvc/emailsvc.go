// Package emailsvc is the Go port of the Node email-service (R2 consolidation).
//
// It exposes POST /send, builds an RFC 5322 message from {to,subject,html,text}
// and hands it to SMTP — a faithful port of the NestJS MailController +
// MailService (nodemailer), so an internal caller (newsletter, gdpr, …) cannot
// tell which runtime served it. Running it inside the orchestrator binary
// instead of a ~50 MiB Node runtime is the R2 footprint win.
//
// The real internal caller posts /send with only Content-Type (no identity
// envelope) and relies on docker-network isolation, so — like the Node
// controller behind the cluster boundary and like logsvc — the route is mounted
// plainly; the host middleware owns transport-level auth.
package emailsvc

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/smtp"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// emailRe is the same pragmatic shape class-validator's @IsEmail accepts for the
// common case: local@domain.tld with no spaces. Kept deliberately permissive —
// the SMTP server is the real authority on deliverability.
var emailRe = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)

// Service holds the SMTP transport config + the send seam (overridable in tests).
type Service struct {
	log    *slog.Logger
	host   string
	port   int
	secure bool
	user   string
	pass   string
	from   string

	// send is the transport seam. Production uses smtpSend; tests inject a
	// capturing func so the message shape is asserted without a live server.
	send func(m *message) error
}

// New builds the service from env (parity with the Node/compose defaults:
// SMTP_HOST=mailpit, SMTP_PORT=1025, SMTP_SECURE=false, no auth).
func New(log *slog.Logger) *Service {
	s := &Service{
		log:    log,
		host:   shared.EnvStr("SMTP_HOST", "mailpit"),
		port:   shared.EnvInt("SMTP_PORT", 1025),
		secure: shared.EnvStr("SMTP_SECURE", "false") == "true",
		user:   shared.EnvStr("SMTP_USER", ""),
		pass:   shared.EnvStr("SMTP_PASS", ""),
		from:   shared.EnvStr("EMAIL_FROM", "noreply@mini-baas.local"),
	}
	s.send = s.smtpSend
	return s
}

// Name identifies the sub-service to the orchestrator.
func (s *Service) Name() string { return "email" }

// Mount registers the HTTP surface. /health/* and /metrics are owned by the
// shared router, so email only adds its one route.
func (s *Service) Mount(mux *http.ServeMux) {
	mux.HandleFunc("POST /send", s.handleSend)
}

// Run has no background loop (sends are synchronous); it just parks until the
// orchestrator shuts down so the goroutine exits cleanly.
func (s *Service) Run(ctx context.Context) { <-ctx.Done() }

// sendRequest mirrors SendEmailDto.
type sendRequest struct {
	To      string `json:"to"`
	Subject string `json:"subject"`
	HTML    string `json:"html"`
	Text    string `json:"text"`
}

// validate reproduces the DTO constraints: a valid recipient, a non-empty
// subject, and at least one of html/text.
func (r sendRequest) validate() error {
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
		shared.WriteJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_body"})
		return
	}
	if err := req.validate(); err != nil {
		shared.WriteJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
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
		shared.WriteJSON(w, http.StatusBadGateway, map[string]any{"error": "send_failed"})
		return
	}
	s.log.Info("email sent", "messageId", m.messageID, "to", req.To)
	shared.WriteJSON(w, http.StatusOK, map[string]any{"messageId": m.messageID})
}

// Healthy reports SMTP reachability (NOOP handshake), mirroring the Node
// readiness probe. Exposed for callers that want an SMTP-aware readiness.
func (s *Service) Healthy() bool {
	addr := net.JoinHostPort(s.host, strconv.Itoa(s.port))
	d := net.Dialer{Timeout: 3 * time.Second}
	conn, err := d.Dial("tcp", addr)
	if err != nil {
		return false
	}
	c, err := smtp.NewClient(conn, s.host)
	if err != nil {
		_ = conn.Close()
		return false
	}
	defer func() { _ = c.Close() }()
	return c.Noop() == nil
}

// smtpSend is the production transport: implicit TLS when secure, otherwise a
// plain dial with opportunistic STARTTLS (handled by smtp.SendMail). Auth is
// attached only when a user is configured.
func (s *Service) smtpSend(m *message) error {
	addr := net.JoinHostPort(s.host, strconv.Itoa(s.port))
	var auth smtp.Auth
	if s.user != "" {
		auth = smtp.PlainAuth("", s.user, s.pass, s.host)
	}
	if s.secure {
		return s.sendImplicitTLS(addr, auth, m)
	}
	return smtp.SendMail(addr, auth, m.from, []string{m.to}, m.bytes())
}

// sendImplicitTLS handles the secure=true (TLS-on-connect, e.g. :465) path that
// smtp.SendMail does not cover.
func (s *Service) sendImplicitTLS(addr string, auth smtp.Auth, m *message) error {
	conn, err := tls.Dial("tcp", addr, &tls.Config{ServerName: s.host})
	if err != nil {
		return err
	}
	c, err := smtp.NewClient(conn, s.host)
	if err != nil {
		return err
	}
	defer func() { _ = c.Close() }()
	if auth != nil {
		if ok, _ := c.Extension("AUTH"); ok {
			if err := c.Auth(auth); err != nil {
				return err
			}
		}
	}
	if err := c.Mail(m.from); err != nil {
		return err
	}
	if err := c.Rcpt(m.to); err != nil {
		return err
	}
	wc, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := wc.Write(m.bytes()); err != nil {
		return err
	}
	if err := wc.Close(); err != nil {
		return err
	}
	return c.Quit()
}

// message is the built email; bytes() renders the RFC 5322 wire form.
type message struct {
	from      string
	to        string
	subject   string
	html      string
	text      string
	messageID string
}

// bytes renders headers + body. Both html and text → multipart/alternative;
// otherwise the single available representation.
func (m *message) bytes() []byte {
	var b strings.Builder
	b.WriteString("From: " + m.from + "\r\n")
	b.WriteString("To: " + m.to + "\r\n")
	b.WriteString("Subject: " + mime.QEncoding.Encode("utf-8", m.subject) + "\r\n")
	b.WriteString("Message-ID: " + m.messageID + "\r\n")
	b.WriteString("Date: " + time.Now().UTC().Format(time.RFC1123Z) + "\r\n")
	b.WriteString("MIME-Version: 1.0\r\n")

	switch {
	case m.html != "" && m.text != "":
		boundary := "mb_" + randHex(12)
		b.WriteString("Content-Type: multipart/alternative; boundary=\"" + boundary + "\"\r\n\r\n")
		writePart(&b, boundary, "text/plain; charset=utf-8", m.text)
		writePart(&b, boundary, "text/html; charset=utf-8", m.html)
		b.WriteString("--" + boundary + "--\r\n")
	case m.html != "":
		b.WriteString("Content-Type: text/html; charset=utf-8\r\n\r\n")
		b.WriteString(m.html + "\r\n")
	default:
		b.WriteString("Content-Type: text/plain; charset=utf-8\r\n\r\n")
		b.WriteString(m.text + "\r\n")
	}
	return []byte(b.String())
}

func writePart(b *strings.Builder, boundary, contentType, body string) {
	b.WriteString("--" + boundary + "\r\n")
	b.WriteString("Content-Type: " + contentType + "\r\n\r\n")
	b.WriteString(body + "\r\n")
}

// newMessageID mints a unique <hex@domain> id (the SMTP transport's job in
// nodemailer), so the response carries a real, deliverable Message-ID.
func newMessageID(from string) string {
	domain := "mini-baas.local"
	if at := strings.LastIndex(from, "@"); at >= 0 && at+1 < len(from) {
		domain = strings.Trim(from[at+1:], "<> ")
	}
	return "<" + randHex(16) + "@" + domain + ">"
}

func randHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(buf)
}
