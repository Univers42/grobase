package tenants

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ErrNotFound is returned when a tenant or key row doesn't exist.
var ErrNotFound = errors.New("tenant not found")

// ErrConflict is returned on (tenant_id) or (tenant_id, key name) uniqueness violation.
var ErrConflict = errors.New("tenant already exists")

// isUniqueViolation reports whether err is a Postgres 23505 unique-constraint
// violation. pgx may surface this either when the query executes OR later when
// the row is scanned (CTE INSERT...RETURNING), so every INSERT path must check
// it in *both* places — otherwise a duplicate leaks out as a raw 500 instead of
// a clean conflict, which broke Bootstrap idempotency.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// Service implements tenant lifecycle CRUD + key issuance.
type Service struct {
	db        *shared.Postgres
	log       *slog.Logger
	adapter   *AdapterRegistry           // optional; enables mount reconciliation in Provision
	dataPlane *DataPlane                 // optional; enables schema_per_tenant schema creation
	perm      provision.PermissionEngine // optional; the single ABAC role/policy seam
	verifyC   *verifyCache               // B4-verify: Argon2-only-on-first-seen fast path
}

// NewService wires the DB pool. The PermissionEngine seam defaults to the
// SQL backend over the same admin pool (no HTTP decide), so seedDefaultRole has
// exactly one role implementation. SetPermissionEngine can override it.
func NewService(db *shared.Postgres, log *slog.Logger) *Service {
	return &Service{db: db, log: log, perm: provision.NewSQLBackend(db, "", ""), verifyC: newVerifyCache()}
}

// SetPermissionEngine overrides the ABAC seam (e.g. to enable HTTP self-verify).
func (s *Service) SetPermissionEngine(p provision.PermissionEngine) { s.perm = p }

// SetAdapterRegistry wires the adapter-registry client used by Provision to
// register tenant data mounts. Optional — without it Provision still bootstraps
// the tenant but reports each requested mount as an error.
func (s *Service) SetAdapterRegistry(ar *AdapterRegistry) {
	s.adapter = ar
}

// SetDataPlane wires the Rust data-plane client used by Provision to create the
// per-tenant schema for schema_per_tenant mounts. Optional.
func (s *Service) SetDataPlane(dp *DataPlane) {
	s.dataPlane = dp
}

// AdapterClient returns the wired adapter-registry client (or nil if none). The
// dynamic-builder API (MountBuilder) reuses it for caller-scoped mount CRUD,
// rather than constructing a second client — one source of the adapter-registry
// URL + service token.
func (s *Service) AdapterClient() *AdapterRegistry { return s.adapter }

// EnsureSchema checks migration 032 has been applied, then idempotently widens
// the plan CHECK constraint to the current package manifest (migration 035 /
// F1) — self-healing at boot, the same pattern adapter-registry uses for the
// tenant_databases isolation CHECK. Migration 005 pinned the constraint at
// ('free','pro','enterprise'), so without this a plan PATCH to a real tier key
// (nano/basic/essential/max) 500s and PACKAGE_ENFORCEMENT cannot be used.
func (s *Service) EnsureSchema(ctx context.Context) error {
	const q = `SELECT 1 FROM information_schema.tables
	            WHERE table_schema='public' AND table_name='tenants'`
	rows, err := s.db.AdminQuery(ctx, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return errors.New("public.tenants missing — run migration 032_tenants.sql")
	}
	rows.Close() // free the pooled conn before the ALTERs below (defer is a no-op then)

	// Additive + idempotent. Existing rows (free/pro/enterprise, or NULL) all
	// satisfy the widened set, so the ADD never fails on legacy data. Logged,
	// not fatal: a stale constraint degrades tiering, it doesn't stop serving.
	if err := s.db.AdminExec(ctx,
		`ALTER TABLE public.tenants DROP CONSTRAINT IF EXISTS tenants_plan_check`); err != nil {
		s.log.Warn("drop stale tenants_plan_check failed (continuing)", "error", err)
	} else if err := s.db.AdminExec(ctx,
		`ALTER TABLE public.tenants ADD CONSTRAINT tenants_plan_check
		   CHECK (plan IN ('nano','basic','essential','pro','max','free','enterprise'))`); err != nil {
		s.log.Warn("widen tenants_plan_check failed (continuing)", "error", err)
	}
	return nil
}

// selectTenant is the canonical SELECT projection (UUID + slug + everything).
const selectTenant = `
  SELECT id::text AS uuid, slug, name, status, plan, owner_user_id, metadata::text,
         created_at::text, updated_at::text
    FROM public.tenants`

// Create inserts a tenant row keyed by slug. Uses the admin pool because the
// caller has no tenant context yet (chicken-and-egg).
func (s *Service) Create(ctx context.Context, req CreateTenantRequest) (Tenant, error) {
	meta := req.Metadata
	if meta == nil {
		meta = map[string]any{}
	}
	metaJSON, _ := json.Marshal(meta)
	plan := req.Plan
	if plan == "" {
		plan = "free"
	}

	var t Tenant
	row, err := s.queryOne(ctx, `
		WITH inserted AS (
		  INSERT INTO public.tenants (slug, name, plan, owner_user_id, metadata)
		  VALUES ($1, $2, $3, NULLIF($4,''), $5::jsonb)
		  RETURNING id, slug, name, status, plan, owner_user_id, metadata, created_at, updated_at
		)
		SELECT id::text, slug, name, status, plan, owner_user_id, metadata::text,
		       created_at::text, updated_at::text FROM inserted`,
		req.ID, req.Name, plan, req.OwnerUserID, string(metaJSON))
	if err != nil {
		if isUniqueViolation(err) {
			return Tenant{}, ErrConflict
		}
		return Tenant{}, err
	}
	if err := scanTenant(row, &t); err != nil {
		if isUniqueViolation(err) {
			return Tenant{}, ErrConflict
		}
		return Tenant{}, err
	}
	return t, nil
}

// FindOne fetches a tenant by its canonical slug OR its internal UUID.
//
// Canonical convention: the SLUG is the tenant identifier across the product
// surface (api-key VerifyKey returns it, provision scopes mounts by it, the
// query path resolves by it). The UUID is the internal primary key (FK target).
// Accepting both here means admin/control tooling can address a tenant by either
// form without a 404 — a slug never matches `id::text` and vice versa, so the
// OR is unambiguous.
func (s *Service) FindOne(ctx context.Context, slug string) (Tenant, error) {
	var t Tenant
	row, err := s.queryOne(ctx, selectTenant+` WHERE slug = $1 OR id::text = $1`, slug)
	if err != nil {
		return Tenant{}, err
	}
	if err := scanTenant(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Tenant{}, ErrNotFound
		}
		return Tenant{}, err
	}
	return t, nil
}

// List returns active tenants. Admin-only endpoint (no tenant filter).
func (s *Service) List(ctx context.Context) ([]Tenant, error) {
	rows, err := s.db.AdminQuery(ctx, selectTenant+`
		 WHERE status <> 'deleted'
		 ORDER BY created_at DESC
		 LIMIT 500`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Tenant, 0)
	for rows.Next() {
		var t Tenant
		if err := scanTenant(rows, &t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// Update mutates the fields present in the request, keyed by slug.
func (s *Service) Update(ctx context.Context, slug string, req UpdateTenantRequest) (Tenant, error) {
	var metaArg any
	if req.Metadata != nil {
		b, _ := json.Marshal(req.Metadata)
		metaArg = string(b)
	}
	row, err := s.queryOne(ctx, `
		WITH updated AS (
		  UPDATE public.tenants
		     SET name     = COALESCE($2, name),
		         plan     = COALESCE($3, plan),
		         status   = COALESCE($4, status),
		         metadata = COALESCE($5::jsonb, metadata)
		   WHERE slug = $1
		   RETURNING id, slug, name, status, plan, owner_user_id, metadata, created_at, updated_at
		)
		SELECT id::text, slug, name, status, plan, owner_user_id, metadata::text,
		       created_at::text, updated_at::text FROM updated`,
		slug, req.Name, req.Plan, req.Status, metaArg)
	if err != nil {
		return Tenant{}, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Tenant{}, ErrNotFound
		}
		return Tenant{}, err
	}
	return t, nil
}

// SoftDelete sets status='deleted'. Keyed by slug.
func (s *Service) SoftDelete(ctx context.Context, slug string) error {
	tag, err := s.exec(ctx,
		`UPDATE public.tenants SET status='deleted' WHERE slug=$1 AND status<>'deleted'`,
		slug)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// IssueKey generates a new API key for the tenant identified by slug.
// Persists prefix+hash, returns the full cleartext key ONCE.
func (s *Service) IssueKey(ctx context.Context, slug string, req IssueKeyRequest) (IssueKeyResponse, error) {
	if req.Name == "" {
		return IssueKeyResponse{}, fmt.Errorf("name is required")
	}
	scopes := req.Scopes
	if len(scopes) == 0 {
		scopes = []string{"read", "write"}
	}
	prefix, fullKey, hash, err := generateKey()
	if err != nil {
		return IssueKeyResponse{}, err
	}
	var expiresArg any
	if req.ExpiresAt != "" {
		if _, perr := time.Parse(time.RFC3339, req.ExpiresAt); perr != nil {
			return IssueKeyResponse{}, fmt.Errorf("expires_at must be RFC3339")
		}
		expiresArg = req.ExpiresAt
	}

	var out APIKey
	row, err := s.queryOne(ctx, `
		WITH ins AS (
		  INSERT INTO public.tenant_api_keys
		         (tenant_id, name, key_prefix, key_hash, scopes, expires_at)
		  SELECT t.id, $2, $3, $4, $5, $6::timestamptz
		    FROM public.tenants t
		   WHERE t.slug = $1
		  RETURNING id, name, key_prefix, scopes, created_at, expires_at, last_used_at, revoked_at
		)
		SELECT ins.id::text, $1::text, ins.name, ins.key_prefix, ins.scopes,
		       ins.created_at::text, ins.expires_at::text,
		       ins.last_used_at::text, ins.revoked_at::text
		  FROM ins`,
		slug, req.Name, prefix, hash, scopes, expiresArg)
	if err != nil {
		if isUniqueViolation(err) {
			return IssueKeyResponse{}, fmt.Errorf("key name %q already exists for tenant", req.Name)
		}
		return IssueKeyResponse{}, err
	}
	if err := row.Scan(&out.ID, &out.TenantID, &out.Name, &out.KeyPrefix,
		&out.Scopes, &out.CreatedAt, &out.ExpiresAt,
		&out.LastUsedAt, &out.RevokedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return IssueKeyResponse{}, ErrNotFound
		}
		if isUniqueViolation(err) {
			return IssueKeyResponse{}, fmt.Errorf("key name %q already exists for tenant", req.Name)
		}
		return IssueKeyResponse{}, err
	}
	return IssueKeyResponse{APIKey: out, Key: fullKey}, nil
}

// ListKeys returns the redacted view of a tenant's keys, keyed by slug.
func (s *Service) ListKeys(ctx context.Context, slug string) ([]APIKey, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT k.id::text, $1::text AS tenant_slug, k.name, k.key_prefix, k.scopes,
		       k.created_at::text, k.expires_at::text,
		       k.last_used_at::text, k.revoked_at::text
		  FROM public.tenant_api_keys k
		  JOIN public.tenants t ON t.id = k.tenant_id
		 WHERE t.slug = $1
		 ORDER BY k.created_at DESC`, slug)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]APIKey, 0)
	for rows.Next() {
		var k APIKey
		if err := rows.Scan(&k.ID, &k.TenantID, &k.Name, &k.KeyPrefix,
			&k.Scopes, &k.CreatedAt, &k.ExpiresAt, &k.LastUsedAt, &k.RevokedAt); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// RevokeKey marks a key revoked. Keyed by tenant slug + key uuid.
func (s *Service) RevokeKey(ctx context.Context, slug, keyID string) error {
	tag, err := s.exec(ctx, `
		UPDATE public.tenant_api_keys k
		   SET revoked_at = now()
		  FROM public.tenants t
		 WHERE k.id = $1::uuid AND k.tenant_id = t.id
		   AND t.slug = $2 AND k.revoked_at IS NULL`,
		keyID, slug)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	// Drop the verify fast-path cache so the revoked key stops authenticating
	// immediately instead of lingering until its TTL expires.
	s.verifyC.flush()
	// Same for the DATA PLANE's verify cache (B3) — it caches verified
	// identities independently and would keep honoring the revoked key for up
	// to its TTL (~30s). Best-effort: on failure the TTL still bounds exposure.
	if s.dataPlane != nil {
		if err := s.dataPlane.evictVerify(ctx); err != nil {
			s.log.Warn("data-plane evict-verify after key revoke failed", "err", err)
		}
	}
	return nil
}

// FlushVerifyCache drops the local key-verify fast-path cache (and best-effort the
// data plane's) so a credential invalidated out-of-band — e.g. a hard-erased tenant
// (D4.4) — stops authenticating immediately instead of lingering until its TTL.
func (s *Service) FlushVerifyCache() {
	s.verifyC.flush()
	if s.dataPlane != nil {
		if err := s.dataPlane.evictVerify(context.Background()); err != nil {
			s.log.Warn("flush verify cache: data-plane evict failed", "err", err)
		}
	}
}

// VerifyKey resolves a cleartext key to a tenant slug + scopes if valid.
// Updates last_used_at on success. Constant-time hash compare.
func (s *Service) VerifyKey(ctx context.Context, full string) (VerifyKeyResponse, error) {
	prefix, payload, err := parseKey(full)
	if err != nil {
		return VerifyKeyResponse{Valid: false, Reason: "invalid_format"}, nil
	}
	// B4-verify: fast path. A repeat verify of an already-seen key skips both
	// the DB round-trip AND the Argon2id recompute — the measured 40 verify/s
	// wall only applies to first-seen keys now. (last_used_at granularity
	// coarsens to the cache TTL on the hot path; acceptable for a usage stamp.)
	var hash string
	if s.verifyC.enabled() {
		hash = keyHash(full)
		if resp, ok := s.verifyC.get(hash); ok {
			return resp, nil
		}
	}
	rows, err := s.db.AdminQuery(ctx, `
		SELECT k.id::text, t.slug, k.key_hash, k.scopes,
		       coalesce(k.expires_at < now(), false) AS expired
		  FROM public.tenant_api_keys k
		  JOIN public.tenants t ON t.id = k.tenant_id
		 WHERE k.key_prefix = $1 AND k.revoked_at IS NULL`, prefix)
	if err != nil {
		return VerifyKeyResponse{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			keyID, tenantSlug, storedHash string
			scopes                        []string
			expired                       bool
		)
		if err := rows.Scan(&keyID, &tenantSlug, &storedHash, &scopes, &expired); err != nil {
			return VerifyKeyResponse{}, err
		}
		if expired {
			return VerifyKeyResponse{Valid: false, Reason: "expired"}, nil
		}
		if !verifyKeyHash(payload, prefix, storedHash) {
			continue
		}
		go s.touchLastUsed(keyID)
		// Lazy hash migration: the first verify of a legacy argon2id key rewrites
		// it to the fast scheme, so a live fleet drains off argon2 without re-
		// provisioning (best-effort, async; KEY_HASH_UPGRADE=0 disables).
		if !isFastHash(storedHash) && os.Getenv("KEY_HASH_UPGRADE") != "0" {
			go s.upgradeKeyHash(keyID, payload, prefix)
		}
		resp := VerifyKeyResponse{
			Valid:    true,
			TenantID: tenantSlug,
			KeyID:    keyID,
			Scopes:   scopes,
		}
		if s.verifyC.enabled() {
			s.verifyC.put(hash, resp)
		}
		return resp, nil
	}
	return VerifyKeyResponse{Valid: false, Reason: "no_match"}, nil
}

func (s *Service) touchLastUsed(keyID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = s.db.AdminExec(ctx,
		`UPDATE public.tenant_api_keys SET last_used_at = now() WHERE id = $1::uuid`, keyID)
}

// upgradeKeyHash rewrites a legacy argon2id key_hash to the fast scheme after a
// successful verify. The `LIKE 'argon2id$%'` guard makes it idempotent and
// race-safe (a concurrent rotation or a prior upgrade is never clobbered).
func (s *Service) upgradeKeyHash(keyID, payload, prefix string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = s.db.AdminExec(ctx,
		`UPDATE public.tenant_api_keys SET key_hash = $2
		   WHERE id = $1::uuid AND key_hash LIKE 'argon2id$%'`,
		keyID, hashPayloadFast(payload, prefix))
}

// Bootstrap creates a tenant + default ABAC role + first API key in one shot.
//
// The ABAC seeding speaks SQL directly into the same Postgres because
// permission-engine lives in the same DB; cross-service call would be
// transactional gymnastics. If you swap permission-engine to an external
// store, swap this for an HTTP call to it.
func (s *Service) Bootstrap(ctx context.Context, id, name string, req BootstrapRequest) (BootstrapResponse, error) {
	// Self-serve bootstrap has no plan selection — defaults to free ("").
	tenant, created, err := s.findOrCreateBySlug(ctx, id, name, req.OwnerUserID, "")
	if err != nil {
		return BootstrapResponse{}, err
	}

	roles := []string{}
	if req.SeedRoles {
		assigned, rerr := s.seedDefaultRole(ctx, id, req.OwnerUserID, req.DefaultRoleName)
		if rerr != nil {
			s.log.Warn("seed default role failed", "tenant", id, "err", rerr)
		} else if assigned != "" {
			roles = append(roles, assigned)
		}
	}

	keyName := strings.TrimSpace(req.DefaultKeyName)
	if keyName == "" {
		keyName = "default"
	}

	// Idempotent key issuance: reuse an existing active key with this name
	// rather than re-minting a secret (which would invalidate live clients).
	// Mirrors BootstrapForUser so both bootstrap paths behave identically.
	existing, err := s.findActiveKeyByName(ctx, id, keyName)
	if err != nil {
		return BootstrapResponse{}, err
	}
	if existing != nil {
		return BootstrapResponse{Tenant: tenant, Roles: roles, Created: created, KeyReuse: true}, nil
	}

	key, err := s.IssueKey(ctx, id, IssueKeyRequest{Name: keyName, Scopes: []string{"read", "write", "admin"}})
	if err != nil {
		return BootstrapResponse{}, fmt.Errorf("issue first key: %w", err)
	}
	return BootstrapResponse{Tenant: tenant, APIKey: &key, Roles: roles, Created: created}, nil
}

// findOrCreateBySlug creates the tenant or returns the existing one. The second
// return reports whether it was created this call. Idempotent — relies on
// Create mapping a 23505 to ErrConflict (see isUniqueViolation).
func (s *Service) findOrCreateBySlug(ctx context.Context, id, name, ownerUserID, plan string) (Tenant, bool, error) {
	t, err := s.Create(ctx, CreateTenantRequest{ID: id, Name: name, OwnerUserID: ownerUserID, Plan: plan})
	if err == nil {
		return t, true, nil
	}
	if !errors.Is(err, ErrConflict) {
		return Tenant{}, false, err
	}
	t, err = s.FindOne(ctx, id)
	if err != nil {
		return Tenant{}, false, err
	}
	return t, false, nil
}

// SelfBootstrapResult is the response shape for the JWT-authenticated bootstrap.
type SelfBootstrapResult struct {
	Tenant   Tenant            `json:"tenant"`
	APIKey   *IssueKeyResponse `json:"api_key,omitempty"`
	Created  bool              `json:"created"`
	KeyReuse bool              `json:"key_reuse,omitempty"`
}

// BootstrapForUser is the authenticated-by-JWT counterpart to Bootstrap.
//
// The GoTrue post-signup trigger (migration 033) is expected to have created
// the tenant row already. This method:
//  1. Looks up the existing tenant by owner_user_id.
//  2. Defensive UPSERT if the trigger failed for any reason (auto-recovery).
//  3. Issues a "default" API key if the tenant doesn't already have an
//     active one with that name. Otherwise returns just the tenant — we
//     never re-mint a key for an existing one (would invalidate clients).
func (s *Service) BootstrapForUser(ctx context.Context, userID, email, defaultKeyName string) (SelfBootstrapResult, error) {
	if userID == "" {
		return SelfBootstrapResult{}, fmt.Errorf("user_id is required")
	}
	if defaultKeyName == "" {
		defaultKeyName = "default"
	}

	tenant, created, err := s.findOrCreateForUser(ctx, userID, email)
	if err != nil {
		return SelfBootstrapResult{}, err
	}

	// If an active key with the requested name already exists, return the
	// tenant alone — we will not surface a usable secret a second time.
	existingKey, err := s.findActiveKeyByName(ctx, tenant.ID, defaultKeyName)
	if err != nil {
		return SelfBootstrapResult{}, err
	}
	if existingKey != nil {
		return SelfBootstrapResult{
			Tenant:   tenant,
			Created:  created,
			KeyReuse: true,
		}, nil
	}

	key, err := s.IssueKey(ctx, tenant.ID, IssueKeyRequest{
		Name:   defaultKeyName,
		Scopes: []string{"read", "write", "admin"},
	})
	if err != nil {
		return SelfBootstrapResult{}, fmt.Errorf("issue first key: %w", err)
	}
	return SelfBootstrapResult{
		Tenant:  tenant,
		APIKey:  &key,
		Created: created,
	}, nil
}

// findForUser resolves the tenant owned by userID WITHOUT creating one. It
// returns ErrNotFound when the user owns no tenant yet — tenant creation is the
// explicit job of POST /v1/tenants/me/bootstrap, never a side effect of a /me
// read. (Self-serve reads use this; the bootstrap path keeps findOrCreateForUser.)
func (s *Service) findForUser(ctx context.Context, userID string) (Tenant, error) {
	row, err := s.queryOne(ctx, selectTenant+` WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return Tenant{}, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Tenant{}, ErrNotFound
		}
		return Tenant{}, err
	}
	return t, nil
}

func (s *Service) findOrCreateForUser(ctx context.Context, userID, email string) (Tenant, bool, error) {
	row, err := s.queryOne(ctx, selectTenant+` WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return Tenant{}, false, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err == nil {
		return t, false, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return Tenant{}, false, err
	}

	// Defensive: trigger failed or backfill missed this user. Create now.
	slug := slugFromUserUUID(userID)
	name := email
	if name == "" {
		name = slug
	}
	created, err := s.Create(ctx, CreateTenantRequest{
		ID:          slug,
		Name:        name,
		OwnerUserID: userID,
	})
	if errors.Is(err, ErrConflict) {
		// Race: another caller (or the trigger) inserted it between our
		// SELECT and our INSERT. Re-fetch.
		row2, err2 := s.queryOne(ctx, selectTenant+` WHERE slug = $1`, slug)
		if err2 != nil {
			return Tenant{}, false, err2
		}
		if err2 := scanTenant(row2, &t); err2 != nil {
			return Tenant{}, false, err2
		}
		return t, false, nil
	}
	if err != nil {
		return Tenant{}, false, err
	}
	return created, true, nil
}

func (s *Service) findActiveKeyByName(ctx context.Context, tenantSlug, keyName string) (*APIKey, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT k.id::text, $1::text, k.name, k.key_prefix, k.scopes,
		       k.created_at::text, k.expires_at::text,
		       k.last_used_at::text, k.revoked_at::text
		  FROM public.tenant_api_keys k
		  JOIN public.tenants t ON t.id = k.tenant_id
		 WHERE t.slug = $1 AND k.name = $2 AND k.revoked_at IS NULL
		 LIMIT 1`, tenantSlug, keyName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, nil
	}
	var k APIKey
	if err := rows.Scan(&k.ID, &k.TenantID, &k.Name, &k.KeyPrefix,
		&k.Scopes, &k.CreatedAt, &k.ExpiresAt, &k.LastUsedAt, &k.RevokedAt); err != nil {
		return nil, err
	}
	return &k, nil
}

// slugFromUserUUID mirrors the SQL trigger so Go and PG generate the same slug.
func slugFromUserUUID(userUUID string) string {
	out := make([]rune, 0, 2+len(userUUID))
	out = append(out, 't', '-')
	for _, r := range userUUID {
		if r == '-' {
			continue
		}
		out = append(out, r)
	}
	return string(out)
}

// seedDefaultRole ensures the tenant owner holds a baseline ABAC role, via the
// single PermissionEngine seam (one role implementation shared with the
// reconciler). It creates a SLUG-NAMESPACED role (`<slug>:<role>`) so two
// tenants requesting the same logical role do not collide on the global
// UNIQUE(roles.name) — the prior implementation could only assign an existing
// global role for exactly this reason. The role gets the baseline owner-scoped
// CRUD policy (Defaults().RolePolicy) and is granted to the owner.
//
// Idempotent: re-running re-uses the role/policy/assignment (no duplicate rows).
// Returns the namespaced role name actually assigned.
func (s *Service) seedDefaultRole(ctx context.Context, slug, ownerUserID, requestedRole string) (string, error) {
	if !uuidRe.MatchString(ownerUserID) {
		return "", fmt.Errorf("owner_user_id %q is not a UUID; ABAC role not seeded", ownerUserID)
	}
	roleName := strings.TrimSpace(requestedRole)
	if roleName == "" {
		roleName = provision.D().RoleName
	}
	spec := provision.RoleSpec{
		Name:     strings.ToLower(roleName),
		Policies: []provision.PolicySpec{provision.D().RolePolicy},
	}
	roleID, _, err := s.perm.EnsureRole(ctx, slug, spec)
	if err != nil {
		return "", err
	}
	for _, p := range spec.Policies {
		if _, perr := s.perm.EnsurePolicy(ctx, roleID, p); perr != nil {
			return "", perr
		}
	}
	namespaced := provision.NamespacedRoleName(provision.RoleKey(slug, spec.Name))
	if err := s.perm.AssignRole(ctx, ownerUserID, namespaced); err != nil {
		return "", err
	}
	return namespaced, nil
}

func scanTenant(row interface{ Scan(...any) error }, t *Tenant) error {
	var metaJSON string
	if err := row.Scan(&t.UUID, &t.ID, &t.Name, &t.Status, &t.Plan, &t.OwnerUserID,
		&metaJSON, &t.CreatedAt, &t.UpdatedAt); err != nil {
		return err
	}
	t.Metadata = map[string]any{}
	if metaJSON != "" {
		_ = json.Unmarshal([]byte(metaJSON), &t.Metadata)
	}
	return nil
}

// queryOne wraps pool.QueryRow so we can keep all SQL on the admin path.
func (s *Service) queryOne(ctx context.Context, sql string, args ...any) (pgx.Row, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return &singleRow{rows: rows}, nil
}

// exec runs a non-returning statement via the admin pool, returning the tag.
func (s *Service) exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return pgconn.CommandTag{}, err
	}
	for rows.Next() { /* drain */
	}
	return rows.CommandTag(), rows.Err()
}

// singleRow lets a multi-row pgx.Rows behave like a single pgx.Row, returning
// pgx.ErrNoRows when the cursor is empty.
type singleRow struct {
	rows pgx.Rows
}

func (s *singleRow) Scan(dest ...any) error {
	defer s.rows.Close()
	if !s.rows.Next() {
		if err := s.rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return s.rows.Scan(dest...)
}
