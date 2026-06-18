package tenants

import (
	"crypto/rand"
	"encoding/base32"
	"strings"
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

// errInvalidFormat reports a structurally invalid key (see tenantsErr).
const errInvalidFormat tenantsErr = "api key has invalid format"

// b32 returns the no-padding StdEncoding base32 encoder. It is cheap to
// construct and immutable, so building it per call (replacing the former
// package-level singleton) is byte-identical to the prior alphabet/padding.
func b32() *base32.Encoding {
	return base32.StdEncoding.WithPadding(base32.NoPadding)
}

// generateKey returns a (prefix, fullKey) pair plus an argon2id hash of the
// payload portion. The payload is what gets hashed — the prefix is in
// cleartext so we can look it up cheaply. The prefix random buffer is sized so
// its base32 encoding yields prefixLen chars (~8 raw bytes → 12 base32 chars).
func (h *keyHasher) generateKey() (prefix, fullKey, hash string, err error) {
	pBytes := make([]byte, (prefixLen*5+7)/8)
	if _, err = rand.Read(pBytes); err != nil {
		return "", "", "", err
	}
	prefix = strings.ToLower(b32().EncodeToString(pBytes))[:prefixLen]

	payload := make([]byte, payloadBytes)
	if _, err = rand.Read(payload); err != nil {
		return "", "", "", err
	}
	payloadStr := strings.ToLower(b32().EncodeToString(payload))

	fullKey = keyHeader + prefix + "_" + payloadStr
	hash = h.selectHash(payloadStr, prefix)
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
