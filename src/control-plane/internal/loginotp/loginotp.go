// Package loginotp implements an email login OTP — a 6-digit code mailed to an
// account's registered address and entered back in the terminal (a Bitwarden-style
// second factor before login). The code is stored only as a peppered sha256 hash;
// protection is the pepper (offline-leak resistance), a short TTL, and a hard attempt
// cap. On success it mints a short-lived proof the login step requires.
//
// CONTROL-PLANE ONLY. FLAG-GATED OFF = PARITY: the /v1/auth/otp/* routes mount ONLY
// when EMAIL_OTP_ENABLED is truthy. The SMTP transport (SMTP_HOST/PORT/USER/PASS) +
// EMAIL_FROM (falling back to MAIL_PRO) are injected; a gate points SMTP at a mock.
package loginotp

import (
	"log/slog"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// loginotpErr is the package's const-error type (errors.Is works; no package var).
type loginotpErr string

func (e loginotpErr) Error() string { return string(e) }

const (
	// ErrNoCode — no active (unconsumed, unexpired) code for the email (401, generic).
	ErrNoCode loginotpErr = "no active code"
	// ErrExpired — the latest code has expired (410).
	ErrExpired loginotpErr = "code expired"
	// ErrLocked — the attempt cap was reached (429).
	ErrLocked loginotpErr = "too many attempts"
	// ErrInvalid — the code did not match (401).
	ErrInvalid loginotpErr = "invalid code"
)

// smtpConfig is the injected SMTP transport (mirrors emailsvc env parity).
type smtpConfig struct {
	host   string
	port   int
	secure bool
	user   string
	pass   string
	from   string
}

// Service issues + verifies email login OTPs. Dependencies are injected (no globals);
// `now` + `send` are seams for deterministic + offline tests.
type Service struct {
	db          *pg.Postgres
	log         *slog.Logger
	now         func() time.Time
	pepper      []byte
	jwtSecret   []byte
	ttl         time.Duration
	maxAttempts int
	smtp        smtpConfig
	send        func(to, subject, body string) error
}

// New builds the service from env (SMTP parity with emailsvc; EMAIL_FROM falls back to
// MAIL_PRO so the address already in .env.local is the sender).
func New(db *pg.Postgres, log *slog.Logger) *Service {
	s := &Service{
		db:          db,
		log:         log,
		now:         time.Now,
		pepper:      []byte(os.Getenv("KEY_HASH_PEPPER")),
		jwtSecret:   []byte(os.Getenv("GOTRUE_JWT_SECRET")),
		ttl:         time.Duration(config.EnvInt("EMAIL_OTP_TTL_SECS", 300)) * time.Second,
		maxAttempts: config.EnvInt("EMAIL_OTP_MAX_ATTEMPTS", 5),
		smtp: smtpConfig{
			host:   config.EnvStr("SMTP_HOST", "mailpit"),
			port:   config.EnvInt("SMTP_PORT", 1025),
			secure: config.EnvStr("SMTP_SECURE", "false") == "true",
			user:   config.EnvStr("SMTP_USER", ""),
			pass:   config.EnvStr("SMTP_PASS", ""),
			from:   emailFrom(),
		},
	}
	s.send = s.smtpSend
	return s
}

// emailFrom resolves the sender address: EMAIL_FROM, then MAIL_PRO, then a default.
func emailFrom() string {
	if v := os.Getenv("EMAIL_FROM"); v != "" {
		return v
	}
	if v := os.Getenv("MAIL_PRO"); v != "" {
		return v
	}
	return "noreply@grobase.local"
}
