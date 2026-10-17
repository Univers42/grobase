// Package smtpclient is the one SMTP transport shared by emailsvc and loginotp,
// so port 465 means implicit TLS (RFC 8314) in every sender and the dial,
// deadline and AUTH rules exist once.
//
// Caveat: Timeout bounds the WHOLE session (dial, greeting, auth, DATA, QUIT)
// with one connection deadline, not each step. A legitimately slow relay that
// needs longer than Timeout (default 30s) fails; raise Config.Timeout. Error
// scrubbing replaces the exact password string only, so a server that echoes a
// transformed form (base64 of the AUTH blob) is not caught.
package smtpclient

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/smtp"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
)

const (
	dialTimeout    = 10 * time.Second
	defaultTimeout = 30 * time.Second
)

// Config is one SMTP relay. RootCAs and Timeout are test hooks, never read from env.
type Config struct {
	Host    string
	Port    int
	Secure  bool
	User    string
	Pass    string
	From    string
	Timeout time.Duration
	RootCAs *x509.CertPool
}

// FromEnv reads SMTP_HOST/PORT/SECURE/USER/PASS and the sender from EMAIL_FROM,
// then each fallback env key in order. From is empty when none is set.
func FromEnv(fromFallbacks ...string) Config {
	c := Config{
		Host:   config.EnvStr("SMTP_HOST", "mailpit"),
		Port:   config.EnvInt("SMTP_PORT", 1025),
		Secure: config.EnvStr("SMTP_SECURE", "false") == "true",
		User:   config.EnvStr("SMTP_USER", ""),
		Pass:   config.EnvStr("SMTP_PASS", ""),
	}
	for _, key := range append([]string{"EMAIL_FROM"}, fromFallbacks...) {
		if v := os.Getenv(key); v != "" {
			c.From = v
			break
		}
	}
	return c
}

// ImplicitTLS reports whether the connection speaks TLS before any SMTP byte.
func (c Config) ImplicitTLS() bool { return c.Secure || c.Port == 465 }

func (c Config) timeout() time.Duration {
	if c.Timeout > 0 {
		return c.Timeout
	}
	return defaultTimeout
}

func (c Config) tlsConfig() *tls.Config {
	return &tls.Config{ServerName: c.Host, MinVersion: tls.VersionTLS12, RootCAs: c.RootCAs}
}

// open dials per ImplicitTLS and returns a client whose connection carries the
// session deadline. The caller closes it.
func (c Config) open() (*smtp.Client, error) {
	addr := net.JoinHostPort(c.Host, strconv.Itoa(c.Port))
	d := &net.Dialer{Timeout: dialTimeout}
	conn, err := d.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	// The deadline is set before the TLS handshake on purpose: tls.DialWithDialer
	// bounds the handshake by Dialer.Timeout, so a server that accepts and never
	// answers would hold a 465 send for dialTimeout instead of c.timeout().
	if err := conn.SetDeadline(time.Now().Add(c.timeout())); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if c.ImplicitTLS() {
		tc := tls.Client(conn, c.tlsConfig())
		if err := tc.Handshake(); err != nil {
			_ = conn.Close()
			return nil, err
		}
		conn = tc
	}
	cl, err := smtp.NewClient(conn, c.Host)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	return cl, nil
}

// secure upgrades a plain session with STARTTLS when the server offers it.
func (c Config) secure(cl *smtp.Client) error {
	if c.ImplicitTLS() {
		return nil
	}
	if ok, _ := cl.Extension("STARTTLS"); ok {
		return cl.StartTLS(c.tlsConfig())
	}
	return nil
}

// authenticate runs PLAIN auth only when a user is set. A server without AUTH
// is an error, not a silent unauthenticated send (smtp.SendMail's rule, now
// applied to the implicit-TLS path too).
func (c Config) authenticate(cl *smtp.Client) error {
	if c.User == "" {
		return nil
	}
	if ok, _ := cl.Extension("AUTH"); !ok {
		return errors.New("smtp: server doesn't support AUTH")
	}
	return cl.Auth(smtp.PlainAuth("", c.User, c.Pass, c.Host))
}

// Send delivers msg from -> to and closes the session.
func Send(c Config, from, to string, msg []byte) error {
	return c.scrub(c.send(from, to, msg))
}

func (c Config) send(from, to string, msg []byte) error {
	cl, err := c.open()
	if err != nil {
		return err
	}
	defer func() { _ = cl.Close() }()
	if err := c.secure(cl); err != nil {
		return err
	}
	if err := c.authenticate(cl); err != nil {
		return err
	}
	if err := cl.Mail(from); err != nil {
		return err
	}
	if err := cl.Rcpt(to); err != nil {
		return err
	}
	wc, err := cl.Data()
	if err != nil {
		return err
	}
	if _, err := wc.Write(msg); err != nil {
		return err
	}
	if err := wc.Close(); err != nil {
		return err
	}
	return cl.Quit()
}

// Ping dials the way Send does (TLS first on 465) and issues NOOP.
func Ping(c Config) error {
	return c.scrub(c.ping())
}

func (c Config) ping() error {
	cl, err := c.open()
	if err != nil {
		return err
	}
	defer func() { _ = cl.Close() }()
	if err := cl.Noop(); err != nil {
		return err
	}
	return cl.Quit()
}

func (c Config) scrub(err error) error {
	if err == nil || c.Pass == "" || !strings.Contains(err.Error(), c.Pass) {
		return err
	}
	return fmt.Errorf("%s", strings.ReplaceAll(err.Error(), c.Pass, "[redacted]"))
}
