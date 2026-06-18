package emailsvc

import (
	"crypto/tls"
	"net"
	"net/smtp"
	"strconv"
	"time"
)

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
	conn, err := tls.Dial("tcp", addr, &tls.Config{ServerName: s.host, MinVersion: tls.VersionTLS12})
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
	return writeMessage(c, m)
}

// writeMessage delivers the envelope + body over an established client and
// closes the session (the Mail/Rcpt/Data/Write/Quit sequence).
func writeMessage(c *smtp.Client, m *message) error {
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
