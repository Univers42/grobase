package passkeys

import (
	"context"
	"errors"
	"log/slog"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

// Service drives the two passkey ceremonies end-to-end:
//
//	register: BeginRegistration → (client/authenticator) → FinishRegistration → store
//	login:    BeginLogin        → (client/authenticator) → FinishLogin → bump count → mint JWT
//
// The cryptography (challenge issuance, attestation parsing, assertion
// signature verification against the stored COSE public key, sign-count
// clone-detection) is the go-webauthn library's; this Service owns the durable
// store, the short-TTL server-side challenge state, and the session mint.
type Service struct {
	wa       *webauthn.WebAuthn
	store    *store
	sessions *sessionStore
	minter   *SessionMinter
	log      *slog.Logger
}

// Config configures the relying party. RPID is the registrable domain (e.g.
// "example.com"); RPOrigins are the exact origins the client runs on (e.g.
// "https://app.example.com"). A mismatch between the asserted origin and
// RPOrigins is rejected BY THE LIBRARY — the origin bind is part of why a stolen
// assertion cannot be replayed against another site.
type Config struct {
	RPID          string
	RPDisplayName string
	RPOrigins     []string
}

// NewService builds the relying party + ceremony engine.
func NewService(db pdb, cfg Config, minter *SessionMinter, log *slog.Logger) (*Service, error) {
	wa, err := webauthn.New(&webauthn.Config{
		RPID:          cfg.RPID,
		RPDisplayName: cfg.RPDisplayName,
		RPOrigins:     cfg.RPOrigins,
	})
	if err != nil {
		return nil, err
	}
	return &Service{
		wa:       wa,
		store:    newStore(db),
		sessions: newSessionStore(),
		minter:   minter,
		log:      log,
	}, nil
}

// BeginRegister starts a registration ceremony for (tenant,user). It returns the
// CredentialCreation options (handed verbatim to navigator.credentials.create on
// the client) and a one-time challengeID the client echoes back on finish. The
// server-side SessionData (carrying the challenge) is retained under that id —
// never trusted from the client — so the challenge cannot be forged.
func (s *Service) BeginRegister(ctx context.Context, in BeginRegisterInput) (*protocol.CredentialCreation, string, error) {
	stored, err := s.store.LoadByUser(ctx, in.TenantID, in.UserID)
	if err != nil && !errors.Is(err, ErrNoCredentials) {
		return nil, "", err
	}
	display := displayOr(in.DisplayName, in.Name)
	user, err := newUser(in.UserID, in.Name, display, stored)
	if err != nil {
		return nil, "", err
	}
	// Exclude already-registered credentials so the same authenticator is not
	// double-registered for this user.
	creation, session, err := s.wa.BeginRegistration(user,
		webauthn.WithExclusions(withAllowCredentials(stored)))
	if err != nil {
		return nil, "", err
	}
	id, err := s.sessions.put(pending{
		session: session, tenantID: in.TenantID, userID: in.UserID,
		userName: in.Name, display: display,
	})
	if err != nil {
		return nil, "", err
	}
	return creation, id, nil
}

// FinishRegister verifies the authenticator's attestation response, persists the
// new credential, and returns its (base64url) id. A missing/expired/replayed
// challengeID returns ErrChallengeNotFound (the single-use, TTL-bounded session
// store guarantees a challenge cannot be reused). The attestation body is parsed
// from the raw JSON the client posted.
func (s *Service) FinishRegister(ctx context.Context, challengeID string, body []byte) (string, error) {
	p, ok := s.sessions.take(challengeID)
	if !ok {
		return "", ErrChallengeNotFound
	}
	user, err := s.buildUser(ctx, p.tenantID, p.userID, p.userName, p.display)
	if err != nil {
		return "", err
	}
	parsed, err := protocol.ParseCredentialCreationResponseBytes(body)
	if err != nil {
		return "", wrapProtocol(err)
	}
	cred, err := s.wa.CreateCredential(user, *p.session, parsed)
	if err != nil {
		return "", wrapProtocol(err)
	}
	sc := encodeCredential(cred, p.tenantID, p.userID, p.userName)
	if err := s.store.Insert(ctx, sc); err != nil {
		return "", err
	}
	return sc.CredentialID, nil
}

// The login ceremony (BeginLogin / FinishLogin and its helpers) lives in login.go.

// buildUser loads the durable user object for the finish path (registration
// needs the EXISTING credentials so go-webauthn can apply exclusions; an empty
// set is fine for a first registration).
func (s *Service) buildUser(ctx context.Context, tenantID, userID, name, display string) (*webauthnUser, error) {
	stored, err := s.store.LoadByUser(ctx, tenantID, userID)
	if err != nil && !errors.Is(err, ErrNoCredentials) {
		return nil, err
	}
	return newUser(userID, name, display, stored)
}

// Sentinels mapped to HTTP status by the handler.
var (
	// ErrChallengeNotFound: the begin→finish challenge id is missing, expired, or
	// already consumed (single-use). → 404.
	ErrChallengeNotFound = errors.New("passkeys: challenge not found or expired")
	// ErrAssertionRejected: the login assertion failed verification (wrong key,
	// wrong/replayed challenge, cross-user credential, bad signature). → 401.
	ErrAssertionRejected = errors.New("passkeys: assertion rejected")
)

// Package-level helpers (wrapProtocol / displayOr / resolveEmail /
// base64urlEncode) live in helpers.go.
