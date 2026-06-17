// Package passkeys implements server-side WebAuthn / passkey ceremonies
// (Track-D D2c) — net-new enterprise auth gotrue does not provide.
//
// It owns:
//   - public.webauthn_credentials CRUD (migration 050)
//   - POST /v1/auth/passkeys/register/begin|finish  (registration ceremony)
//   - POST /v1/auth/passkeys/login/begin|finish      (authentication ceremony)
//
// The cryptographic ceremony (challenge generation, attestation parsing,
// assertion signature verification, sign-count clone detection) is delegated to
// the maintained github.com/go-webauthn/webauthn library; this package owns the
// HTTP surface, the durable credential store, and the short-TTL server-side
// challenge state. On a successful login it mints the SAME GoTrue-shaped HS256
// JWT the rest of the control plane verifies, so a passkey login yields a
// session interchangeable with a password login.
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when PASSKEYS_ENABLED is
// truthy. When OFF (the default) Mount is never called, so none of the
// /v1/auth/passkeys/* routes exist and a request 404s, and the
// webauthn_credentials table is never consulted — byte-identical to today.
package passkeys

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// pdb is the minimal Postgres surface the store needs. *pg.Postgres
// satisfies it (the passkeys service runs as the BYPASSRLS control-plane role);
// a fake satisfies it in unit tests so the ceremony logic is provable without a
// live database.
type pdb interface {
	AdminExec(ctx context.Context, sql string, args ...any) error
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// ErrNoCredentials is returned by LoadByUser when a user has no registered
// passkey (login/begin then cannot offer any allowCredentials).
var ErrNoCredentials = errors.New("passkeys: no credentials registered for user")

// storedCredential is the durable row shape. The WebAuthn-typed projection
// (webauthn.Credential) is built from this in service.go so the store stays
// engine-only (no go-webauthn import here keeps the SQL surface testable).
type storedCredential struct {
	ID           string
	TenantID     string
	UserID       string
	Name         string
	CredentialID string // base64url
	PublicKey    string // base64-std (COSE)
	SignCount    uint32
	AAGUID       string // base64-std
	Transports   string // comma-joined
}

// store is the durable credential layer over public.webauthn_credentials.
type store struct{ db pdb }

func newStore(db pdb) *store { return &store{db: db} }

// Insert persists a freshly registered credential. The UNIQUE(credential_id)
// constraint is the final backstop against re-registering an existing id.
func (s *store) Insert(ctx context.Context, c storedCredential) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.webauthn_credentials
		  (tenant_id, user_id, name, credential_id, public_key, sign_count, aaguid, transports)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
		c.TenantID, c.UserID, c.Name, c.CredentialID, c.PublicKey,
		int64(c.SignCount), c.AAGUID, c.Transports)
}

// LoadByUser returns every credential for a (tenant,user). tenant_id is bound
// when non-empty (the cross-tenant wall atop RLS); an empty tenant scopes by
// user only (single-tenant / untenanted deployments).
func (s *store) LoadByUser(ctx context.Context, tenantID, userID string) ([]storedCredential, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT id, tenant_id, user_id, name, credential_id, public_key, sign_count, aaguid, transports
		  FROM public.webauthn_credentials
		 WHERE user_id = $1 AND ($2 = '' OR tenant_id = $2)
		 ORDER BY created_at ASC`, userID, tenantID)
	if err != nil {
		return nil, err
	}
	out, err := scanCredentials(rows)
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, ErrNoCredentials
	}
	return out, nil
}

// LoadByCredentialID resolves the credential the login assertion references. It
// binds tenant_id when non-empty so a credential id from one tenant cannot be
// asserted against another tenant's row (the credential_id is globally unique,
// but the tenant bind is defense-in-depth on the multi-tenant edge).
func (s *store) LoadByCredentialID(ctx context.Context, tenantID, credentialID string) (storedCredential, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT id, tenant_id, user_id, name, credential_id, public_key, sign_count, aaguid, transports
		  FROM public.webauthn_credentials
		 WHERE credential_id = $1 AND ($2 = '' OR tenant_id = $2)
		 LIMIT 1`, credentialID, tenantID)
	if err != nil {
		return storedCredential{}, err
	}
	out, err := scanCredentials(rows)
	if err != nil {
		return storedCredential{}, err
	}
	if len(out) == 0 {
		return storedCredential{}, ErrNoCredentials
	}
	return out[0], nil
}

// BumpSignCount persists the authenticator's new signature counter after a
// verified login. The WHERE re-binds (tenant,credential) so the bump can only
// touch the row that just authenticated. last_used_at records the login time.
func (s *store) BumpSignCount(ctx context.Context, tenantID, credentialID string, newCount uint32) error {
	return s.db.AdminExec(ctx, `
		UPDATE public.webauthn_credentials
		   SET sign_count = $3, last_used_at = $4
		 WHERE credential_id = $1 AND ($2 = '' OR tenant_id = $2)`,
		credentialID, tenantID, int64(newCount), time.Now().UTC())
}

// scanCredentials and transportsCSV live in store_scan.go.
