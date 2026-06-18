package tenants

import (
	"context"
)

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
	s.evictVerifyCaches(ctx, "data-plane evict-verify after key revoke failed")
	return nil
}

// evictVerifyCaches drops the local verify fast-path cache and, best-effort, the
// data plane's verify cache so a revoked/erased key stops authenticating
// immediately instead of lingering until its TTL (~30s). logMsg labels a
// data-plane eviction failure (the TTL still bounds exposure on failure).
func (s *Service) evictVerifyCaches(ctx context.Context, logMsg string) {
	s.verifyC.flush()
	if s.dataPlane != nil {
		if err := s.dataPlane.evictVerify(ctx); err != nil {
			s.log.Warn(logMsg, "err", err)
		}
	}
}

// FlushVerifyCache drops the local key-verify fast-path cache (and best-effort the
// data plane's) so a credential invalidated out-of-band — e.g. a hard-erased tenant
// (D4.4) — stops authenticating immediately instead of lingering until its TTL.
func (s *Service) FlushVerifyCache() {
	s.evictVerifyCaches(context.Background(), "flush verify cache: data-plane evict failed")
}

// findActiveKeyByName returns the tenant's active (non-revoked) key with the
// given name, or nil when none exists. Used by the bootstrap paths for
// idempotent key reuse (never re-mint a secret for an existing key).
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
