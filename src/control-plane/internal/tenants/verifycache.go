package tenants

import (
	"crypto/sha256"
	"encoding/hex"
	"sync"
	"time"
)

// verifyCache is the "Argon2-only-on-first-seen" fast path (B4-verify).
//
// The MEASURED #1 multi-tenant ceiling: under a 1,000-tenant fan-out the
// data-plane's 30 s verify cache collapses to ~10% hit, so ~90% of requests
// reach `VerifyKey`, each forcing an Argon2id recompute (32 MiB, bounded to
// ARGON2_MAX_CONCURRENT=2 → ~40 verify/s wall → 502 timeouts). Argon2 exists to
// make STORED hashes expensive to brute-force offline; it has no security value
// on the REPEAT verify of a *presented* high-entropy key (the caller already
// holds the cleartext). So we cache the verified identity keyed by a fast
// SHA-256 of the presented key: the first verify of a key pays Argon2 once, and
// every repeat within the TTL is a hash-map lookup. The cold-start Argon2 cost
// becomes a one-time warmup, not a per-request tax — and it scales with
// stateless tenant-control replicas.
//
// Only POSITIVE results are cached (mirrors the data-plane verify cache), so a
// not-yet-created key is never poisoned. Revocation/expiry propagate within the
// TTL (default 60 s) — the same staleness window the data plane already accepts.
// Disabled (exact pre-existing behavior) when the TTL is 0.
type verifyCache struct {
	mu  sync.RWMutex
	m   map[string]verifyCacheEntry
	ttl time.Duration
	max int
	now func() time.Time // injectable for tests
}

type verifyCacheEntry struct {
	resp    VerifyKeyResponse
	expires time.Time
}

func newVerifyCache() *verifyCache {
	return &verifyCache{
		m:   make(map[string]verifyCacheEntry),
		ttl: envDurationMS("TENANT_CONTROL_VERIFY_CACHE_TTL_MS", 60_000),
		max: envInt("TENANT_CONTROL_VERIFY_CACHE_MAX", 16_384),
		now: time.Now,
	}
}

// enabled reports whether caching is on (TTL > 0).
func (c *verifyCache) enabled() bool { return c != nil && c.ttl > 0 }

// keyHash is a fast, non-reversible lookup token for a cleartext key. SHA-256 of
// a 49-char high-entropy key is collision/preimage-safe for this purpose; the
// cleartext is never stored or logged.
func keyHash(full string) string {
	sum := sha256.Sum256([]byte(full))
	return hex.EncodeToString(sum[:])
}

// get returns a cached positive result if present and unexpired.
func (c *verifyCache) get(h string) (VerifyKeyResponse, bool) {
	if !c.enabled() {
		return VerifyKeyResponse{}, false
	}
	c.mu.RLock()
	e, ok := c.m[h]
	c.mu.RUnlock()
	if !ok || c.now().After(e.expires) {
		return VerifyKeyResponse{}, false
	}
	return e.resp, true
}

// put stores a positive result. Bounded: when at capacity it first sweeps
// expired entries, then evicts one arbitrary entry if still full — O(n) only on
// the rare full-insert, never on the hot get path.
func (c *verifyCache) put(h string, resp VerifyKeyResponse) {
	if !c.enabled() || !resp.Valid {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.m) >= c.max {
		now := c.now()
		for k, e := range c.m {
			if now.After(e.expires) {
				delete(c.m, k)
			}
		}
		if len(c.m) >= c.max {
			for k := range c.m { // evict one arbitrary entry to make room
				delete(c.m, k)
				break
			}
		}
	}
	c.m[h] = verifyCacheEntry{resp: resp, expires: c.now().Add(c.ttl)}
}
