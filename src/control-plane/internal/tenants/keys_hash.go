package tenants

import (
	"crypto/hmac"
	"crypto/sha256"
	"os"
	"strings"
)

// fastHashTag prefixes the SHA-256 key-hash scheme. The verify path keys off
// this string to decide argon2id (legacy) vs sha256 (fast).
const fastHashTag = "sha256$v=1$"

// selectHash picks the stored-hash scheme for a NEW key. Default: the fast
// SHA-256 scheme. Set KEY_HASH_LEGACY_ARGON2=1 to mint argon2id hashes (revert).
//
// WHY THIS IS NOT A SECURITY DOWNGRADE — read before "fixing" it back:
// argon2id is a PASSWORD hash: it exists to make brute-forcing a *low-entropy
// human secret* expensive offline. Our API-key payload is 20 bytes from
// crypto/rand = 160 bits of uniform entropy. There is nothing to brute-force:
// recovering one key from its hash is ~2^159 work at ANY hash speed — infeasible
// for SHA-256 just as for argon2id. So the 32 MiB / ~50 ms argon2id cost buys
// zero security here while capping verify at ARGON2_MAX_CONCURRENT=2 → the
// measured #1 multi-tenant wall (10K sparse fan-out: every cache-miss = a 32 MiB
// argon2 recompute → tenant-control floods → 502). Fast hashing is exactly what
// GitHub/Stripe/Supabase do for high-entropy tokens. The verify side accepts
// BOTH schemes (parity), so no existing key breaks; legacy hashes lazy-upgrade
// on first verify. Optional defense-in-depth pepper: KEY_HASH_PEPPER (HMAC).
func (h *keyHasher) selectHash(payload, prefix string) string {
	if os.Getenv("KEY_HASH_LEGACY_ARGON2") == "1" {
		return h.hashPayload(payload, prefix)
	}
	return hashPayloadFast(payload, prefix)
}

// hashPayloadFast computes the fast scheme: SHA-256(salt || payload), or
// HMAC-SHA256(pepper; salt || payload) when KEY_HASH_PEPPER is set (a stolen DB
// alone then cannot verify keys). The prefix-derived salt keeps per-key hashes
// distinct; verify recomputes it from (payload, prefix), so it need not be read
// back from storage. ~microseconds, no large allocation, unbounded concurrency.
func hashPayloadFast(payload, prefix string) string {
	salt := "mbk-f1-" + prefix
	var sum []byte
	if pepper := os.Getenv("KEY_HASH_PEPPER"); pepper != "" {
		mac := hmacSHA256([]byte(pepper), salt+payload)
		sum = mac
	} else {
		h := sha256.Sum256([]byte(salt + payload))
		sum = h[:]
	}
	return fastHashTag + b32().EncodeToString([]byte(salt)) + "$" + b32().EncodeToString(sum)
}

// isFastHash reports whether a stored hash uses the fast scheme (vs legacy
// argon2id). Used both to route verification and to drive lazy upgrade.
func isFastHash(storedHash string) bool {
	return strings.HasPrefix(storedHash, fastHashTag)
}

func hmacSHA256(key []byte, msg string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(msg))
	return m.Sum(nil)
}
