// Package scim implements the Track-D D2b SCIM 2.0 provisioning surface
// (RFC 7644 — System for Cross-domain Identity Management). An enterprise IdP
// (Okta / Entra / OneLogin) drives user lifecycle into Grobase over a bearer
// credential: POST/GET/PUT/PATCH/DELETE /scim/v2/Users. SCIM provisions ORG
// MEMBERS — the humans above a project — so every provisioning op delegates to
// the EXISTING internal/orgs service (Add/Remove member); SCIM owns only the
// bearer-token store, the SCIM resource <-> member mapping, and the SCIM JSON
// shapes.
//
// THE LOAD-BEARING CONSTRAINT (D-026): SCIM is a CONTROL-PLANE operation. It
// NEVER enters RequestIdentity, the RLS GUCs (app.current_tenant_id /
// request.tenant_id), or the data plane. The bearer token resolves to a
// tenant_id (+ a concrete org_id); that tenant binding is the per-tenant wall —
// a T1 token can never read or modify a SCIM resource provisioned under T2.
// Per-request isolation + SHARE_POOLS (24,887 tenants -> 1 pool) stay untouched.
//
// SECURITY (kernel rule #7): a SCIM bearer token is HIGH-ENTROPY, so it is hashed
// with a FAST hash (sha256), NOT a password hash — the SAME discipline as
// tenant_api_keys.key_hash and org_invites.token_hash. The cleartext is returned
// ONCE at issue time and never persisted.
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when SCIM_ENABLED is truthy.
// When OFF (the default) Mount is never called, so none of the /scim/v2/* routes
// exist (404), no scim_tokens/scim_users row is ever written, and
// org_members.active stays true for every row — byte-identical to today.
package scim

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// ErrTokenInvalid is the load-bearing reject: a missing/unknown/revoked SCIM
// bearer token. The handler maps it to 401 (RFC 7644 §3.12).
var ErrTokenInvalid = errors.New("scim bearer token invalid")

// ErrNotFound is returned when a SCIM resource (user) does not exist within the
// bound tenant. Mapped to 404 by the handler.
var ErrNotFound = errors.New("scim resource not found")

// ErrNoOrg is returned when a provisioning op runs under a token with no org_id
// bound (provisioning needs a concrete org to add the member to). Mapped to 400.
var ErrNoOrg = errors.New("scim token is not bound to an org")

// TokenBinding is what VerifyToken resolves: the tenant (+ optional org) a SCIM
// bearer token authorizes. TenantID is the per-tenant wall; OrgID is the org
// provisioning lands on. TokenID identifies the row (for Touch).
type TokenBinding struct {
	TokenID  string
	TenantID string
	OrgID    string
}

// store is the SCIM persistence layer. It speaks SQL over the admin pool
// (BYPASSRLS service_role) and ALWAYS binds tenant_id in its WHERE clauses
// (defense-in-depth behind the RLS policies in migration 054).
type store struct {
	db *shared.Postgres
}

func newStore(db *shared.Postgres) *store { return &store{db: db} }

// hashToken is the fast, non-reversible lookup token for a cleartext SCIM bearer
// (sha256 lower-hex). A high-entropy token → fast hash (kernel rule #7); the
// cleartext is never stored or logged. Mirrors tenants.keyHash / the
// org_invites token discipline.
func hashToken(cleartext string) string {
	sum := sha256.Sum256([]byte(cleartext))
	return hex.EncodeToString(sum[:])
}

// newCleartextToken mints a 256-bit high-entropy bearer token (base64url, no
// padding). The returned string is shown to the IdP admin ONCE; only its sha256
// is persisted.
func newCleartextToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "scim_" + base64.RawURLEncoding.EncodeToString(b), nil
}

// IssueToken creates a SCIM bearer token for (tenantID, orgID) and returns the
// CLEARTEXT once. Only the sha256 is stored. orgID may be empty (set later), but
// provisioning ops fail with ErrNoOrg until it is bound.
func (s *store) IssueToken(ctx context.Context, tenantID, orgID, description string) (cleartext, tokenID string, err error) {
	cleartext, err = newCleartextToken()
	if err != nil {
		return "", "", err
	}
	rows, err := s.db.AdminQuery(ctx, `
		INSERT INTO public.scim_tokens (tenant_id, org_id, token_hash, description)
		VALUES ($1, NULLIF($2,''), $3, $4)
		RETURNING id::text`,
		tenantID, orgID, hashToken(cleartext), description)
	if err != nil {
		return "", "", err
	}
	defer rows.Close()
	if !rows.Next() {
		return "", "", rows.Err()
	}
	if err := rows.Scan(&tokenID); err != nil {
		return "", "", err
	}
	return cleartext, tokenID, nil
}

// VerifyToken resolves a cleartext SCIM bearer to its TokenBinding (the tenant +
// org it authorizes). A token that is unknown OR revoked (revoked_at IS NOT NULL)
// returns ErrTokenInvalid — this IS the per-tenant wall + the revocation gate.
func (s *store) VerifyToken(ctx context.Context, cleartext string) (TokenBinding, error) {
	if strings.TrimSpace(cleartext) == "" {
		return TokenBinding{}, ErrTokenInvalid
	}
	rows, err := s.db.AdminQuery(ctx, `
		SELECT id::text, tenant_id, COALESCE(org_id,'')
		  FROM public.scim_tokens
		 WHERE token_hash = $1 AND revoked_at IS NULL`,
		hashToken(cleartext))
	if err != nil {
		return TokenBinding{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		if rows.Err() != nil {
			return TokenBinding{}, rows.Err()
		}
		return TokenBinding{}, ErrTokenInvalid
	}
	var b TokenBinding
	if err := rows.Scan(&b.TokenID, &b.TenantID, &b.OrgID); err != nil {
		return TokenBinding{}, err
	}
	return b, nil
}

// Touch stamps last_used_at on a token (best-effort observability of IdP sync
// activity). A failure here never fails the SCIM request.
func (s *store) Touch(ctx context.Context, tokenID string) {
	_ = s.db.AdminExec(ctx,
		`UPDATE public.scim_tokens SET last_used_at = now() WHERE id = $1::uuid`, tokenID)
}

// Revoke marks a token revoked (idempotent). After this, VerifyToken returns
// ErrTokenInvalid for it — the load-bearing revocation gate.
func (s *store) Revoke(ctx context.Context, tenantID, tokenID string) error {
	return s.db.AdminExec(ctx,
		`UPDATE public.scim_tokens SET revoked_at = now()
		   WHERE id = $1::uuid AND tenant_id = $2 AND revoked_at IS NULL`,
		tokenID, tenantID)
}

// ── scim_users mapping ───────────────────────────────────────────────────────

// userRecord is the persisted SCIM user mapping (the wall-scoped resource).
type userRecord struct {
	SCIMID      string
	TenantID    string
	OrgID       string
	UserName    string
	UserID      string
	DisplayName string
	Emails      []SCIMEmail
	Active      bool
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// InsertUser creates the SCIM user mapping row. Keyed UNIQUE(tenant_id, scim_id)
// — the per-tenant namespace. emails is serialized as jsonb.
func (s *store) InsertUser(ctx context.Context, u userRecord) error {
	emailJSON, _ := json.Marshal(u.Emails)
	return s.db.AdminExec(ctx, `
		INSERT INTO public.scim_users
		  (tenant_id, org_id, scim_id, user_name, user_id, display_name, emails, active)
		VALUES ($1, NULLIF($2,''), $3, $4, $5, $6, $7::jsonb, $8)`,
		u.TenantID, u.OrgID, u.SCIMID, u.UserName, u.UserID,
		u.DisplayName, string(emailJSON), u.Active)
}

// GetUser fetches one SCIM user by (tenantID, scimID). ErrNotFound if absent —
// note the tenant_id bind: a T2 token can never resolve a T1 scim_id.
func (s *store) GetUser(ctx context.Context, tenantID, scimID string) (userRecord, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT scim_id, tenant_id, COALESCE(org_id,''), user_name, user_id,
		       display_name, emails::text, active, created_at, updated_at
		  FROM public.scim_users
		 WHERE tenant_id = $1 AND scim_id = $2`, tenantID, scimID)
	if err != nil {
		return userRecord{}, err
	}
	return scanUser(rows)
}

// FindByUserName resolves a SCIM user by (tenantID, userName) — backs the
// filter=userName eq "x" query. Case-insensitive (matches the lower(user_name)
// index). ErrNotFound when no row.
func (s *store) FindByUserName(ctx context.Context, tenantID, userName string) (userRecord, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT scim_id, tenant_id, COALESCE(org_id,''), user_name, user_id,
		       display_name, emails::text, active, created_at, updated_at
		  FROM public.scim_users
		 WHERE tenant_id = $1 AND lower(user_name) = lower($2)
		 LIMIT 1`, tenantID, userName)
	if err != nil {
		return userRecord{}, err
	}
	return scanUser(rows)
}

// UpdateUser replaces the mutable fields of a SCIM user (PUT / PATCH). Keyed by
// (tenantID, scimID) — the wall.
func (s *store) UpdateUser(ctx context.Context, u userRecord) error {
	emailJSON, _ := json.Marshal(u.Emails)
	return s.db.AdminExec(ctx, `
		UPDATE public.scim_users
		   SET user_name = $3, display_name = $4, emails = $5::jsonb,
		       active = $6, updated_at = now()
		 WHERE tenant_id = $1 AND scim_id = $2`,
		u.TenantID, u.SCIMID, u.UserName, u.DisplayName, string(emailJSON), u.Active)
}

// SetActive flips the SCIM user's active flag (deactivate / reactivate). Keyed by
// the wall. It also mirrors the flag onto org_members.active (the soft-disable),
// scoped by org_id+user_id so it never touches another org's membership.
func (s *store) SetActive(ctx context.Context, u userRecord, active bool) error {
	if err := s.db.AdminExec(ctx, `
		UPDATE public.scim_users SET active = $3, updated_at = now()
		 WHERE tenant_id = $1 AND scim_id = $2`,
		u.TenantID, u.SCIMID, active); err != nil {
		return err
	}
	if u.OrgID == "" {
		return nil
	}
	return s.db.AdminExec(ctx, `
		UPDATE public.org_members SET active = $3
		 WHERE org_id::text = $1 AND user_id = $2`,
		u.OrgID, u.UserID, active)
}

// DeleteUser removes the SCIM mapping row (the org membership removal is done by
// the service via orgs.Service.RemoveMember). Keyed by the wall.
func (s *store) DeleteUser(ctx context.Context, tenantID, scimID string) error {
	return s.db.AdminExec(ctx,
		`DELETE FROM public.scim_users WHERE tenant_id = $1 AND scim_id = $2`,
		tenantID, scimID)
}

// scanUser reads exactly one userRecord from a result set, ErrNotFound if empty.
func scanUser(rows pgx.Rows) (userRecord, error) {
	defer rows.Close()
	if !rows.Next() {
		if rows.Err() != nil {
			return userRecord{}, rows.Err()
		}
		return userRecord{}, ErrNotFound
	}
	var u userRecord
	var emailJSON string
	if err := rows.Scan(&u.SCIMID, &u.TenantID, &u.OrgID, &u.UserName, &u.UserID,
		&u.DisplayName, &emailJSON, &u.Active, &u.CreatedAt, &u.UpdatedAt); err != nil {
		return userRecord{}, err
	}
	u.Emails = []SCIMEmail{}
	if emailJSON != "" {
		_ = json.Unmarshal([]byte(emailJSON), &u.Emails)
	}
	return u, nil
}
