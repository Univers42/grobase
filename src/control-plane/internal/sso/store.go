package sso

import (
	"context"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// Store is the durable sso_connections registry (migration 053). It speaks SQL
// over the admin pool (BYPASSRLS service_role) and ALWAYS binds tenant_id in its
// WHERE — the Go capability gate is the first wall, the per-tenant RLS policy on
// sso_connections is the second. The client secret is sealed (AES-256-GCM) on
// Insert and opened on read, so the plaintext never lives in a column.
type Store struct {
	db     *pg.Postgres
	sealer *secretSealer
}

// NewStore wires the DB pool + the secret sealer (the AEAD over SSO_SECRET_KEY).
func NewStore(db *pg.Postgres, sealer *secretSealer) *Store {
	return &Store{db: db, sealer: sealer}
}

const selectConn = `
  SELECT id::text, tenant_id, COALESCE(org_id,''), provider, issuer, client_id,
         client_secret_enc, authorize_url, token_url, COALESCE(jwks_url,''),
         redirect_uri, COALESCE(email_domain,''), default_role, created_at
    FROM public.sso_connections`

// Insert seals the client secret and persists a new connection, returning the
// stored row (secret decrypted back into memory). A duplicate (tenant, issuer)
// maps to ErrConflict.
func (s *Store) Insert(ctx context.Context, in RegisterInput) (Connection, error) {
	enc, err := s.sealer.seal(in.ClientSecret)
	if err != nil {
		return Connection{}, err
	}
	role := in.DefaultRole
	if role == "" {
		role = "member"
	}
	rows, err := s.db.AdminQuery(ctx, insertConn,
		in.TenantID, in.OrgID, in.Issuer, in.ClientID, enc,
		in.AuthorizeURL, in.TokenURL, in.JWKSURL, in.RedirectURI, in.EmailDomain, role)
	if err != nil {
		if pg.IsUniqueViolation(err) {
			return Connection{}, ErrConflict
		}
		return Connection{}, err
	}
	return s.scanOne(rows)
}

const insertConn = `
	INSERT INTO public.sso_connections
	  (tenant_id, org_id, provider, issuer, client_id, client_secret_enc,
	   authorize_url, token_url, jwks_url, redirect_uri, email_domain, default_role)
	VALUES ($1, NULLIF($2,''), 'oidc', $3, $4, $5,
	        $6, $7, NULLIF($8,''), $9, NULLIF($10,''), $11)
	RETURNING id::text, tenant_id, COALESCE(org_id,''), provider, issuer, client_id,
	          client_secret_enc, authorize_url, token_url, COALESCE(jwks_url,''),
	          redirect_uri, COALESCE(email_domain,''), default_role, created_at`
