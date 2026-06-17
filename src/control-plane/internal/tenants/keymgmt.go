package tenants

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

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
		if shared.IsUniqueViolation(err) {
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
		if shared.IsUniqueViolation(err) {
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
