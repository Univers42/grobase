package tenants

import (
	"os"
	"strconv"
	"time"
)

// flush drops every cached entry. Called on revocation: we can't target the
// single key (the cache is keyed by the cleartext's hash, which a revoke-by-id
// doesn't have), and revokes are rare, so a full flush is the correct, cheap
// choice — it only forces the next verify of each live key to re-run once.
func (c *verifyCache) flush() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.m = make(map[string]verifyCacheEntry)
	c.mu.Unlock()
}

// envInt reads a positive int env var, returning def when unset/unparseable or
// non-positive. (Distinct from shared.EnvInt, which accepts zero/negative.)
func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return def
}

// envDurationMS reads a non-negative millisecond duration env var, returning
// defMS when unset/unparseable or negative.
func envDurationMS(name string, defMS int) time.Duration {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v >= 0 {
		return time.Duration(v) * time.Millisecond
	}
	return time.Duration(defMS) * time.Millisecond
}
