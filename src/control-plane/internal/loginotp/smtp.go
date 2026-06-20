package loginotp

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/smtp"
	"strconv"
)

// smtp.go — the production email transport (mirrors emailsvc): plain dial with
// opportunistic STARTTLS, or implicit TLS when secure. Auth attached only when a user
// is configured. Tests inject a capturing `send` instead.

// smtpSend builds an RFC 5322 message and delivers it over SMTP.
func (s *Service) smtpSend(to, subject, body string) error {
	msg := buildMessage(s.smtp.from, to, subject, body)
	addr := net.JoinHostPort(s.smtp.host, strconv.Itoa(s.smtp.port))
	var auth smtp.Auth
	if s.smtp.user != "" {
		auth = smtp.PlainAuth("", s.smtp.user, s.smtp.pass, s.smtp.host)
	}
	if s.smtp.secure {
		return s.sendTLS(addr, auth, to, msg)
	}
	return smtp.SendMail(addr, auth, s.smtp.from, []string{to}, msg)
}

// buildMessage renders a minimal text/plain RFC 5322 message.
func buildMessage(from, to, subject, body string) []byte {
	return []byte(fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s\r\n",
		from, to, subject, body))
}

// sendTLS handles the implicit-TLS (secure=true, e.g. :465) path that
// smtp.SendMail does not cover.
func (s *Service) sendTLS(addr string, auth smtp.Auth, to string, msg []byte) error {
	conn, err := tls.Dial("tcp", addr, &tls.Config{ServerName: s.smtp.host, MinVersion: tls.VersionTLS12})
	if err != nil {
		return err
	}
	c, err := smtp.NewClient(conn, s.smtp.host)
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
	if err := c.Mail(s.smtp.from); err != nil {
		return err
	}
	if err := c.Rcpt(to); err != nil {
		return err
	}
	wc, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := wc.Write(msg); err != nil {
		return err
	}
	if err := wc.Close(); err != nil {
		return err
	}
	return c.Quit()
}
