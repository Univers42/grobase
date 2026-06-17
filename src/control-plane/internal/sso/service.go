package sso

import (
	"context"
	"log/slog"
	"strings"
)

// Service drives the OIDC authorization-code login: it resolves a connection,
// mints the single-use state + nonce, exchanges the code, verifies the id_token,
// JIT-resolves the tenant user, and mints a GoTrue-shaped session JWT. It is
// control-plane-only — it never touches the data plane, RequestIdentity, or the
// RLS GUCs; the tenant resolution is by the connection's tenant_id, recorded at
// registration, so org/tenant scoping stays in the control plane by construction.
type Service struct {
	store  *Store
	states *stateStore
	minter *SessionMinter
	log    *slog.Logger
}

// NewService wires the durable store, the in-memory single-use state store, the
// session minter (the SAME HS256 secret tenants.JWTVerifier accepts), and a
// logger.
func NewService(store *Store, minter *SessionMinter, log *slog.Logger) *Service {
	return &Service{store: store, states: newStateStore(), minter: minter, log: log}
}

// BeginInput is the BeginLogin request: EITHER a connection_id (explicit) OR an
// email (resolve by the email's domain within the tenant). TenantID scopes the
// email-domain lookup (mandatory — no cross-tenant resolution).
type BeginInput struct {
	TenantID     string
	ConnectionID string
	Email        string
}

// BeginResult is what the begin handler returns: the IdP authorize URL the client
// redirects to, plus the single-use state it must echo back on callback.
type BeginResult struct {
	AuthorizeURL string `json:"authorize_url"`
	State        string `json:"state"`
}

// BeginLogin resolves the connection, mints a single-use state + nonce, stores
// them server-side keyed by state, and returns the IdP authorize URL. The nonce
// is bound into the authorize request and MUST come back inside the id_token.
func (s *Service) BeginLogin(ctx context.Context, in BeginInput) (BeginResult, error) {
	conn, err := s.resolveConnection(ctx, in)
	if err != nil {
		return BeginResult{}, err
	}
	nonce, err := randomToken()
	if err != nil {
		return BeginResult{}, err
	}
	state, err := s.states.put(loginState{connID: conn.ID, nonce: nonce})
	if err != nil {
		return BeginResult{}, err
	}
	return BeginResult{
		AuthorizeURL: buildAuthorizeURL(conn, state, nonce),
		State:        state,
	}, nil
}

// resolveConnection picks the connection by explicit id, or by the email's domain
// within the tenant. A missing connection is ErrConnectionNotFound.
func (s *Service) resolveConnection(ctx context.Context, in BeginInput) (Connection, error) {
	if id := strings.TrimSpace(in.ConnectionID); id != "" {
		return s.store.GetByID(ctx, id)
	}
	email := strings.TrimSpace(in.Email)
	if email == "" {
		return Connection{}, ErrValidation
	}
	at := strings.LastIndex(email, "@")
	if at < 0 || at == len(email)-1 {
		return Connection{}, ErrValidation
	}
	domain := strings.ToLower(email[at+1:])
	if strings.TrimSpace(in.TenantID) == "" {
		// Without a tenant scope an email-domain lookup would be a cross-tenant
		// scan — refuse it. The caller must name a connection_id (or send the
		// tenant header) for an untenanted deployment.
		return Connection{}, ErrValidation
	}
	return s.store.GetByEmailDomain(ctx, in.TenantID, domain)
}

// FinishLogin consumes the single-use state, exchanges the code at the IdP,
// verifies the returned id_token (signature + iss/aud/exp/nonce), resolves the
// user from the verified claims, and mints a session JWT. A missing/expired/
// replayed state is ErrStateNotFound; any id_token verification failure is
// ErrTokenRejected — NO session is minted in either case.
func (s *Service) FinishLogin(ctx context.Context, state, code string) (MintedSession, error) {
	if strings.TrimSpace(state) == "" || strings.TrimSpace(code) == "" {
		return MintedSession{}, ErrValidation
	}
	ls, ok := s.states.take(state) // single-use: even a same-state retry misses.
	if !ok {
		return MintedSession{}, ErrStateNotFound
	}
	conn, err := s.store.GetByID(ctx, ls.connID)
	if err != nil {
		return MintedSession{}, err
	}
	return s.verifyAndMint(ctx, conn, code, ls.nonce)
}

// verifyAndMint exchanges the code, verifies the id_token, and mints the
// GoTrue-shaped session. The OIDC `sub` is the stable subject and becomes the
// session's `sub`. A fuller JIT path would upsert an org membership using
// conn.DefaultRole/conn.OrgID; that lives in the orgs package and is intentionally
// NOT reinvented here — this slice's contract is "verify -> mint a session".
func (s *Service) verifyAndMint(ctx context.Context, conn Connection, code, nonce string) (MintedSession, error) {
	rawIDToken, err := exchangeCode(ctx, conn, code)
	if err != nil {
		return MintedSession{}, err
	}
	claims, err := verifyIDToken(ctx, conn, rawIDToken, nonce)
	if err != nil {
		return MintedSession{}, err
	}
	session, err := s.minter.Mint(claims.Subject, claims.Email)
	if err != nil {
		return MintedSession{}, err
	}
	if s.log != nil {
		s.log.Info("sso login", "tenant", conn.TenantID, "issuer", conn.Issuer, "sub", claims.Subject)
	}
	return session, nil
}
