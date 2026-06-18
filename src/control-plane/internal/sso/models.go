// Package sso implements enterprise OIDC single-sign-on at the org/tenant level
// (Track-D D2a). It is FLAG-GATED OFF by default (SSO_ENABLED): when off, none of
// its routes are mounted and the sso_connections table (migration 053) is never
// consulted, so the stack stays byte-parity with the OSS edition.
//
// The flow is the OIDC authorization-code grant:
//
//	BeginLogin(connection_id | email)  -> {authorize_url, state}
//	    user authenticates at the IdP, the IdP redirects back with ?code&state
//	FinishLogin(state, code)           -> verify the id_token -> JIT user ->
//	                                      mint a GoTrue-shaped session JWT
//
// The minted session is interchangeable with a password / passkey session: it is
// an HS256 JWT verifiable by the EXISTING tenants.JWTVerifier (same secret, same
// claim shape), produced by the SAME SessionMinter pattern internal/passkeys uses.
// This is control-plane-only: it never touches the data plane, RequestIdentity, or
// the RLS GUCs — org/tenant scoping stays in the control plane by construction.
package sso

import (
	"time"
)

// ssoErr is the package's const error type — sentinels are typed string
// constants so the package keeps zero package-level vars while preserving
// errors.Is / %w / errors.Join identity (a const string is comparable, so two
// values of the same const are equal).
type ssoErr string

func (e ssoErr) Error() string { return string(e) }

// Sentinel errors mapped to HTTP status by the handler:
//
//	ErrConnectionNotFound -> 404 (no such connection / email domain)
//	ErrStateNotFound      -> 401 (missing/expired/replayed state — single-use)
//	ErrTokenRejected      -> 401 (id_token failed verification: sig/iss/aud/exp/nonce)
//	ErrConflict           -> 409 (duplicate (tenant, issuer) on register)
//	ErrValidation         -> 400 (bad input)
const (
	ErrConnectionNotFound ssoErr = "sso: connection not found"
	ErrStateNotFound      ssoErr = "sso: login state not found, expired, or already used"
	ErrTokenRejected      ssoErr = "sso: id_token verification failed"
	ErrConflict           ssoErr = "sso: a connection for this issuer already exists"
	ErrValidation         ssoErr = "sso: validation error"
	// errNoKey guards sealing — SSO cannot store a client secret without a key. The
	// handler only registers the AEAD when SSO_SECRET_KEY is configured.
	errNoKey ssoErr = "sso: SSO_SECRET_KEY not configured"
	// errNoSecret guards minting — an SSO login cannot issue a session without the
	// shared GoTrue secret. main.go only enables the SSO API when the secret is
	// configured, so this is a programmer-error backstop.
	errNoSecret ssoErr = "sso: session secret not configured"
)

// Connection is one configured OIDC IdP for one tenant (optionally one org). It
// carries everything BeginLogin / FinishLogin need to drive + verify the grant.
// ClientSecret holds the DECRYPTED secret in memory only after a store read; the
// durable column is AES-256-GCM ciphertext (crypto.go), never the plaintext.
type Connection struct {
	ID           string    `json:"id"`
	TenantID     string    `json:"tenant_id"`
	OrgID        string    `json:"org_id,omitempty"`
	Provider     string    `json:"provider"`
	Issuer       string    `json:"issuer"`
	ClientID     string    `json:"client_id"`
	ClientSecret string    `json:"-"` // decrypted in memory only; never serialized
	AuthorizeURL string    `json:"authorize_url"`
	TokenURL     string    `json:"token_url"`
	JWKSURL      string    `json:"jwks_url,omitempty"`
	RedirectURI  string    `json:"redirect_uri"`
	EmailDomain  string    `json:"email_domain,omitempty"`
	DefaultRole  string    `json:"default_role"`
	CreatedAt    time.Time `json:"created_at"`
}

// RegisterInput is the admin register-connection request body. ClientSecret is
// the plaintext OIDC client secret; the store seals it before persisting.
type RegisterInput struct {
	TenantID     string `json:"-"` // taken from the {id} path segment, not the body
	OrgID        string `json:"org_id"`
	Issuer       string `json:"issuer"`
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	AuthorizeURL string `json:"authorize_url"`
	TokenURL     string `json:"token_url"`
	JWKSURL      string `json:"jwks_url"`
	RedirectURI  string `json:"redirect_uri"`
	EmailDomain  string `json:"email_domain"`
	DefaultRole  string `json:"default_role"`
}

// idTokenClaims is the subset of OIDC id_token claims we verify + extract. iss is
// matched against the connection's issuer; aud against its client_id; nonce
// against the per-login nonce we minted; sub/email are the resolved identity.
type idTokenClaims struct {
	Issuer   string
	Audience []string
	Subject  string
	Email    string
	Nonce    string
	Expiry   time.Time
}
