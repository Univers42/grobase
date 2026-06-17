package sso

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Store is the durable sso_connections registry (migration 053). It speaks SQL
// over the admin pool (BYPASSRLS service_role) and ALWAYS binds tenant_id in its
// WHERE — the Go capability gate is the first wall, the per-tenant RLS policy on
// sso_connections is the second. The client secret is sealed (AES-256-GCM) on
// Insert and opened on read, so the plaintext never lives in a column.
type Store struct {
	db     *shared.Postgres
	sealer *secretSealer
}

// NewStore wires the DB pool + the secret sealer (the AEAD over SSO_SECRET_KEY).
func NewStore(db *shared.Postgres, sealer *secretSealer) *Store {
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
	rows, err := s.db.AdminQuery(ctx, `
		INSERT INTO public.sso_connections
		  (tenant_id, org_id, provider, issuer, client_id, client_secret_enc,
		   authorize_url, token_url, jwks_url, redirect_uri, email_domain, default_role)
		VALUES ($1, NULLIF($2,''), 'oidc', $3, $4, $5,
		        $6, $7, NULLIF($8,''), $9, NULLIF($10,''), $11)
		RETURNING id::text, tenant_id, COALESCE(org_id,''), provider, issuer, client_id,
		          client_secret_enc, authorize_url, token_url, COALESCE(jwks_url,''),
		          redirect_uri, COALESCE(email_domain,''), default_role, created_at`,
		in.TenantID, in.OrgID, in.Issuer, in.ClientID, enc,
		in.AuthorizeURL, in.TokenURL, in.JWKSURL, in.RedirectURI, in.EmailDomain, role)
	if err != nil {
		if isUniqueViolation(err) {
			return Connection{}, ErrConflict
		}
		return Connection{}, err
	}
	return s.scanOne(rows)
}

// GetByID fetches a connection by its uuid. tenant scoping is NOT applied here
// (the begin path resolves a connection the caller already named); the WHERE on
// id is unique. The decrypted secret is loaded into Connection.ClientSecret.
func (s *Store) GetByID(ctx context.Context, id string) (Connection, error) {
	rows, err := s.db.AdminQuery(ctx, selectConn+` WHERE id::text = $1`, id)
	if err != nil {
		return Connection{}, err
	}
	return s.scanOne(rows)
}

// GetByTenant lists a tenant's connections (tenant_id bound in WHERE). Secrets
// are decrypted back into memory for each row.
func (s *Store) GetByTenant(ctx context.Context, tenantID string) ([]Connection, error) {
	rows, err := s.db.AdminQuery(ctx, selectConn+` WHERE tenant_id = $1 ORDER BY created_at DESC LIMIT 500`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Connection, 0)
	for rows.Next() {
		c, err := s.scanRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// GetByIssuer fetches a connection by (tenant_id, issuer) — the UNIQUE pair. Used
// to verify an id_token's iss resolves to exactly one registered connection.
func (s *Store) GetByIssuer(ctx context.Context, tenantID, issuer string) (Connection, error) {
	rows, err := s.db.AdminQuery(ctx, selectConn+` WHERE tenant_id = $1 AND issuer = $2`, tenantID, issuer)
	if err != nil {
		return Connection{}, err
	}
	return s.scanOne(rows)
}

// GetByEmailDomain resolves a connection by (tenant_id, email_domain) — the
// BeginLogin-by-email path. tenant_id is mandatory (no cross-tenant scan).
func (s *Store) GetByEmailDomain(ctx context.Context, tenantID, domain string) (Connection, error) {
	rows, err := s.db.AdminQuery(ctx,
		selectConn+` WHERE tenant_id = $1 AND email_domain = $2 ORDER BY created_at DESC LIMIT 1`,
		tenantID, domain)
	if err != nil {
		return Connection{}, err
	}
	return s.scanOne(rows)
}

// scanOne reads exactly one row (ErrConnectionNotFound when none).
func (s *Store) scanOne(rows pgx.Rows) (Connection, error) {
	defer rows.Close()
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return Connection{}, err
		}
		return Connection{}, ErrConnectionNotFound
	}
	return s.scanRow(rows)
}

// scanRow scans the selectConn column list AND decrypts the sealed secret into
// Connection.ClientSecret.
func (s *Store) scanRow(rows pgx.Rows) (Connection, error) {
	var c Connection
	var enc []byte
	if err := rows.Scan(&c.ID, &c.TenantID, &c.OrgID, &c.Provider, &c.Issuer, &c.ClientID,
		&enc, &c.AuthorizeURL, &c.TokenURL, &c.JWKSURL, &c.RedirectURI, &c.EmailDomain,
		&c.DefaultRole, &c.CreatedAt); err != nil {
		return Connection{}, err
	}
	secret, err := s.sealer.open(enc)
	if err != nil {
		return Connection{}, err
	}
	c.ClientSecret = secret
	return c, nil
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
