package tenants

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"errors"
	"os"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
)

// API key format: mbk_<prefix>_<payload>
//   prefix : 12 chars base32 (no padding, lowercase). Searchable.
//   payload: 32 chars base32. Hashed; never stored in cleartext.
//
// Total user-visible key length: 4 + 12 + 1 + 32 = 49 chars.

const (
	keyHeader    = "mbk_"
	prefixLen    = 12
	payloadBytes = 20 // 20 raw bytes -> 32 base32 chars
)

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// generateKey returns a (prefix, fullKey) pair plus an argon2id hash of the
// payload portion. The payload is what gets hashed — the prefix is in
// cleartext so we can look it up cheaply.
func generateKey() (prefix, fullKey, hash string, err error) {
	pBytes := make([]byte, (prefixLen*5+7)/8) // ~8 bytes -> 12 base32 chars
	if _, err = rand.Read(pBytes); err != nil {
		return "", "", "", err
	}
	prefix = strings.ToLower(b32.EncodeToString(pBytes))[:prefixLen]

	payload := make([]byte, payloadBytes)
	if _, err = rand.Read(payload); err != nil {
		return "", "", "", err
	}
	payloadStr := strings.ToLower(b32.EncodeToString(payload))

	fullKey = keyHeader + prefix + "_" + payloadStr
	hash = selectHash(payloadStr, prefix)
	return prefix, fullKey, hash, nil
}

// parseKey splits a "mbk_<prefix>_<payload>" key. Returns errInvalidFormat on
// any structural problem; the caller must not leak whether the prefix or the
// payload was the wrong shape (timing-sensitive).
func parseKey(full string) (prefix, payload string, err error) {
	if !strings.HasPrefix(full, keyHeader) {
		return "", "", errInvalidFormat
	}
	rest := full[len(keyHeader):]
	parts := strings.SplitN(rest, "_", 2)
	if len(parts) != 2 || len(parts[0]) != prefixLen {
		return "", "", errInvalidFormat
	}
	if len(parts[1]) < 16 || len(parts[1]) > 64 {
		return "", "", errInvalidFormat
	}
	return parts[0], parts[1], nil
}

// argon2Slots bounds CONCURRENT Argon2id computations. Each one allocates
// memoryCost (32 MiB), so unbounded parallelism under cold-key fan-out OOM-
// kills the container — measured 2026-06-11: a 16-way bulk provision crash-
// looped tenant-control (8 restarts) under its 64 MiB limit, and every
// in-flight request died as a connection EOF. Requests beyond the bound queue
// here (a verify is ~50 ms) instead of killing the identity authority.
// Sized by ARGON2_MAX_CONCURRENT (default 2 → 64 MiB peak hash memory; pair
// with a mem_limit of baseline + slots × 32 MiB).
var argon2Slots = make(chan struct{}, argon2MaxConcurrent())

func argon2MaxConcurrent() int {
	if v, err := strconv.Atoi(os.Getenv("ARGON2_MAX_CONCURRENT")); err == nil && v > 0 {
		return v
	}
	return 2
}

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
func selectHash(payload, prefix string) string {
	if os.Getenv("KEY_HASH_LEGACY_ARGON2") == "1" {
		return hashPayload(payload, prefix)
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
	return fastHashTag + b32.EncodeToString([]byte(salt)) + "$" + b32.EncodeToString(sum)
}

// isFastHash reports whether a stored hash uses the fast scheme (vs legacy
// argon2id). Used both to route verification and to drive lazy upgrade.
func isFastHash(storedHash string) bool {
	return strings.HasPrefix(storedHash, fastHashTag)
}

// hashPayload runs argon2id over (payload || prefix). The prefix doubles as
// the salt so the same payload string yields different hashes per key, but
// we don't need to store a separate salt column.
func hashPayload(payload, prefix string) string {
	const (
		timeCost   = 1
		memoryCost = 32 * 1024 // 32 MiB
		threads    = 2
		outputLen  = 32
	)
	argon2Slots <- struct{}{}
	defer func() { <-argon2Slots }()
	salt := []byte("mbk-v1-" + prefix)
	sum := argon2.IDKey([]byte(payload), salt, timeCost, memoryCost, threads, outputLen)
	return "argon2id$v=1$m=32768,t=1,p=2$" + b32.EncodeToString(salt) + "$" + b32.EncodeToString(sum)
}

// verifyKeyHash returns true iff the payload+prefix recompute to the stored
// hash. The scheme is detected from the stored hash itself (fast sha256 vs
// legacy argon2id), so a fleet mid-migration verifies both. Constant-time
// compare on the inner bytes.
func verifyKeyHash(payload, prefix, storedHash string) bool {
	var expected string
	if isFastHash(storedHash) {
		expected = hashPayloadFast(payload, prefix)
	} else {
		expected = hashPayload(payload, prefix)
	}
	if len(expected) != len(storedHash) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(expected), []byte(storedHash)) == 1
}

func hmacSHA256(key []byte, msg string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(msg))
	return m.Sum(nil)
}

var errInvalidFormat = errors.New("api key has invalid format")
