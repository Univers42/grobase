package tenants

import (
	"context"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

// verifyKeySQL selects candidate (non-revoked) keys sharing the cleartext prefix
// plus an expiry flag, joined to the tenant slug.
const verifyKeySQL = `
	SELECT k.id::text, t.slug, k.key_hash, k.scopes,
	       coalesce(k.expires_at < now(), false) AS expired
	  FROM public.tenant_api_keys k
	  JOIN public.tenants t ON t.id = k.tenant_id
	 WHERE k.key_prefix = $1 AND k.revoked_at IS NULL`

// VerifyKey resolves a cleartext key to a tenant slug + scopes if valid.
// Updates last_used_at on success. Constant-time hash compare.
func (s *Service) VerifyKey(ctx context.Context, full string) (VerifyKeyResponse, error) {
	prefix, payload, err := parseKey(full)
	if err != nil {
		return VerifyKeyResponse{Valid: false, Reason: "invalid_format"}, nil
	}
	hash, cached, hit := s.cacheGet(full)
	if hit {
		return cached, nil
	}
	rows, err := s.db.AdminQuery(ctx, verifyKeySQL, prefix)
	if err != nil {
		return VerifyKeyResponse{}, err
	}
	defer rows.Close()
	resp, err := s.matchKeyRows(rows, prefix, payload)
	if err != nil || !resp.Valid {
		return resp, err
	}
	if s.verifyC.enabled() {
		s.verifyC.put(hash, resp)
	}
	return resp, nil
}

// cacheGet is the B4-verify fast path. A repeat verify of an already-seen key
// skips both the DB round-trip AND the Argon2id recompute — the measured
// 40 verify/s wall only applies to first-seen keys now. (last_used_at
// granularity coarsens to the cache TTL on the hot path; acceptable for a usage
// stamp.) Returns the cache-key hash, the cached response, and whether it hit.
func (s *Service) cacheGet(full string) (string, VerifyKeyResponse, bool) {
	if !s.verifyC.enabled() {
		return "", VerifyKeyResponse{}, false
	}
	hash := keyHash(full)
	resp, ok := s.verifyC.get(hash)
	return hash, resp, ok
}

// matchKeyRows scans the candidate rows for the one whose stored hash matches
// payload+prefix (constant-time). On a match it stamps last_used_at + lazily
// upgrades a legacy hash (both async) and returns a valid response; no match
// returns Reason "no_match", an expired row returns "expired".
func (s *Service) matchKeyRows(rows pgx.Rows, prefix, payload string) (VerifyKeyResponse, error) {
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
		return VerifyKeyResponse{Valid: true, TenantID: tenantSlug, KeyID: keyID, Scopes: scopes}, nil
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
