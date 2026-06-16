package passkeys

import (
	"context"
	"encoding/base64"
	"errors"
	"log/slog"
	"strings"

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
	user, err := newUser(in.UserID, in.Name, displayOr(in.DisplayName, in.Name), stored)
	if err != nil {
		return nil, "", err
	}
	// Exclude already-registered credentials so the same authenticator is not
	// double-registered for this user.
	exclude := withAllowCredentials(stored)
	creation, session, err := s.wa.BeginRegistration(user,
		webauthn.WithExclusions(exclude))
	if err != nil {
		return nil, "", err
	}
	id, err := s.sessions.put(pending{
		session:  session,
		tenantID: in.TenantID,
		userID:   in.UserID,
		userName: in.Name,
		display:  displayOr(in.DisplayName, in.Name),
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

// BeginLogin starts an authentication ceremony for a known user. It loads the
// user's credentials (so the assertion options carry allowCredentials) and
// retains the SessionData under a one-time challengeID. A user with no passkey
// yields ErrNoCredentials (404) — there is nothing to authenticate with.
func (s *Service) BeginLogin(ctx context.Context, in BeginLoginInput) (*protocol.CredentialAssertion, string, error) {
	stored, err := s.store.LoadByUser(ctx, in.TenantID, in.UserID)
	if err != nil {
		return nil, "", err
	}
	user, err := newUser(in.UserID, in.UserID, in.UserID, stored)
	if err != nil {
		return nil, "", err
	}
	assertion, session, err := s.wa.BeginLogin(user)
	if err != nil {
		return nil, "", err
	}
	id, err := s.sessions.put(pending{
		session:  session,
		tenantID: in.TenantID,
		userID:   in.UserID,
	})
	if err != nil {
		return nil, "", err
	}
	return assertion, id, nil
}

// FinishLogin verifies the assertion signature against the stored public key,
// bumps the sign_count, and mints a session JWT. The go-webauthn ValidateLogin
// enforces, against the SERVER-HELD session: the challenge matches, the origin
// matches RPOrigins, the credential id is one this user owns, the signature
// verifies under the stored COSE key, and the sign-count moved forward (clone
// detection). ANY failure → ErrAssertionRejected (401). This is the load-bearing
// reject surface: a wrong-key signature, a replayed/!matching challenge, and a
// cross-user credential all fail here.
func (s *Service) FinishLogin(ctx context.Context, challengeID string, body []byte) (MintedSession, error) {
	p, ok := s.sessions.take(challengeID)
	if !ok {
		return MintedSession{}, ErrChallengeNotFound
	}
	stored, err := s.store.LoadByUser(ctx, p.tenantID, p.userID)
	if err != nil {
		return MintedSession{}, err
	}
	user, err := newUser(p.userID, p.userID, p.userID, stored)
	if err != nil {
		return MintedSession{}, err
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(body)
	if err != nil {
		return MintedSession{}, errors.Join(ErrAssertionRejected, wrapProtocol(err))
	}
	cred, err := s.wa.ValidateLogin(user, *p.session, parsed)
	if err != nil {
		// Every cryptographic / ownership / challenge failure lands here. We map
		// them ALL to a single 401 so the caller cannot distinguish "wrong key"
		// from "wrong credential" from "stale challenge" (no oracle).
		return MintedSession{}, errors.Join(ErrAssertionRejected, err)
	}
	// Persist the advanced authenticator counter (replay/clone evidence). Best-
	// effort: a counter-bump failure must not fail an otherwise valid login, but
	// we log it (a stuck counter weakens replay detection).
	credIDB64 := base64urlEncode(cred.ID)
	if err := s.store.BumpSignCount(ctx, p.tenantID, credIDB64, cred.Authenticator.SignCount); err != nil {
		s.log.Warn("passkeys: sign_count bump failed", "err", err, "credential_id", credIDB64)
	}
	email := resolveEmail(stored, p.userID)
	return s.minter.Mint(p.userID, email)
}

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

// wrapProtocol unwraps go-webauthn's verbose protocol.Error into a compact
// message (its DevInfo is internal detail not for the wire).
func wrapProtocol(err error) error {
	var perr *protocol.Error
	if errors.As(err, &perr) {
		return errors.New(strings.TrimSpace(perr.Type + ": " + perr.Details))
	}
	return err
}

func displayOr(display, fallback string) string {
	if strings.TrimSpace(display) != "" {
		return display
	}
	return fallback
}

// resolveEmail returns the user's email if any stored credential row carried it
// (the name column); otherwise the user id. Passkey login does not require an
// email — the session's authority is the verified credential, not the address.
func resolveEmail(stored []storedCredential, userID string) string {
	for _, sc := range stored {
		if strings.Contains(sc.Name, "@") {
			return sc.Name
		}
	}
	return userID
}

// base64urlEncode encodes a credential id the way the store keys it (base64url,
// no padding) so the post-login sign_count bump targets the right row.
func base64urlEncode(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}
