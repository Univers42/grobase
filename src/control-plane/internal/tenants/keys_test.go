package tenants

import (
	"strings"
	"testing"
)

func TestGenerateKey_FormatAndUniqueness(t *testing.T) {
	prefixA, fullA, hashA, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	prefixB, fullB, hashB, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	if !strings.HasPrefix(fullA, "mbk_") {
		t.Errorf("expected mbk_ prefix, got %q", fullA)
	}
	if !strings.Contains(fullA, prefixA) {
		t.Errorf("full key %q must contain prefix %q", fullA, prefixA)
	}
	if prefixA == prefixB {
		t.Error("two generated keys must not share a prefix")
	}
	if hashA == hashB {
		t.Error("two generated keys must produce distinct hashes")
	}
	if fullA == fullB {
		t.Error("two generated keys must not collide")
	}
}

func TestParseKey_Roundtrip(t *testing.T) {
	prefix, full, _, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	gotPrefix, gotPayload, err := parseKey(full)
	if err != nil {
		t.Fatalf("parseKey: %v", err)
	}
	if gotPrefix != prefix {
		t.Errorf("prefix mismatch: got %q want %q", gotPrefix, prefix)
	}
	if gotPayload == "" {
		t.Error("payload must not be empty")
	}
}

func TestParseKey_Malformed(t *testing.T) {
	cases := []string{
		"",
		"mbk_short_payload",
		"mbk_toolongprefix0_payload",
		"notmbk_aaaaaaaaaaaa_payload",
		"mbk_aaaaaaaaaaaa",
	}
	for _, c := range cases {
		if _, _, err := parseKey(c); err == nil {
			t.Errorf("expected error for %q", c)
		}
	}
}

func TestVerifyKeyHash_MatchesAndRejects(t *testing.T) {
	prefix, full, hash, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	_, payload, err := parseKey(full)
	if err != nil {
		t.Fatalf("parseKey: %v", err)
	}
	if !verifyKeyHash(payload, prefix, hash) {
		t.Error("verifyKeyHash must accept the right payload+prefix")
	}
	if verifyKeyHash(payload+"x", prefix, hash) {
		t.Error("verifyKeyHash must reject a tampered payload")
	}
	if verifyKeyHash(payload, "wrongprefix0", hash) {
		t.Error("verifyKeyHash must reject a wrong prefix (salt)")
	}
}

// TestGenerateKey_DefaultFastScheme: new keys hash with the fast SHA-256 scheme
// (the perf fix), not argon2id, and still verify.
func TestGenerateKey_DefaultFastScheme(t *testing.T) {
	prefix, full, hash, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	if !isFastHash(hash) {
		t.Fatalf("default scheme must be fast (sha256$), got %q", hash)
	}
	if strings.HasPrefix(hash, "argon2id$") {
		t.Error("default scheme must NOT be argon2id")
	}
	_, payload, _ := parseKey(full)
	if !verifyKeyHash(payload, prefix, hash) {
		t.Error("fast hash must verify")
	}
}

// TestVerifyKeyHash_DualScheme: the verify side accepts BOTH a legacy argon2id
// hash and a fast hash for the same key — so a fleet mid-migration never breaks.
func TestVerifyKeyHash_DualScheme(t *testing.T) {
	prefix, full, _, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	_, payload, _ := parseKey(full)

	legacy := hashPayload(payload, prefix)
	fast := hashPayloadFast(payload, prefix)
	if !strings.HasPrefix(legacy, "argon2id$") {
		t.Fatalf("legacy hash shape unexpected: %q", legacy)
	}
	if !isFastHash(fast) {
		t.Fatalf("fast hash shape unexpected: %q", fast)
	}
	if isFastHash(legacy) {
		t.Error("argon2id hash must not be detected as fast")
	}
	if !verifyKeyHash(payload, prefix, legacy) {
		t.Error("must verify a legacy argon2id hash")
	}
	if !verifyKeyHash(payload, prefix, fast) {
		t.Error("must verify a fast sha256 hash")
	}
	// A tampered payload is rejected under either scheme.
	if verifyKeyHash(payload+"x", prefix, legacy) || verifyKeyHash(payload+"x", prefix, fast) {
		t.Error("tampered payload must be rejected under both schemes")
	}
}

// TestHashPayloadFast_DeterministicAndSalted: same input → same hash; the prefix
// is the salt, so a different prefix yields a different hash.
func TestHashPayloadFast_DeterministicAndSalted(t *testing.T) {
	a := hashPayloadFast("payloadpayloadpayload", "prefixaaaaaa")
	b := hashPayloadFast("payloadpayloadpayload", "prefixaaaaaa")
	c := hashPayloadFast("payloadpayloadpayload", "prefixbbbbbb")
	if a != b {
		t.Error("fast hash must be deterministic for identical input")
	}
	if a == c {
		t.Error("fast hash must differ when the prefix (salt) differs")
	}
}

// TestSelectHash_LegacyFlag: KEY_HASH_LEGACY_ARGON2=1 reverts new keys to
// argon2id; default is the fast scheme.
func TestSelectHash_LegacyFlag(t *testing.T) {
	if h := selectHash("payloadpayloadpayload", "prefixaaaaaa"); !isFastHash(h) {
		t.Errorf("default selectHash must be fast, got %q", h)
	}
	t.Setenv("KEY_HASH_LEGACY_ARGON2", "1")
	if h := selectHash("payloadpayloadpayload", "prefixaaaaaa"); !strings.HasPrefix(h, "argon2id$") {
		t.Errorf("KEY_HASH_LEGACY_ARGON2=1 must mint argon2id, got %q", h)
	}
}

// TestHashPayloadFast_Pepper: a server pepper changes the hash (defense in
// depth) and the peppered hash still verifies while the pepper is present.
func TestHashPayloadFast_Pepper(t *testing.T) {
	plain := hashPayloadFast("payloadpayloadpayload", "prefixaaaaaa")
	t.Setenv("KEY_HASH_PEPPER", "super-secret-pepper")
	peppered := hashPayloadFast("payloadpayloadpayload", "prefixaaaaaa")
	if plain == peppered {
		t.Error("pepper must change the hash")
	}
	if !verifyKeyHash("payloadpayloadpayload", "prefixaaaaaa", peppered) {
		t.Error("peppered hash must verify while the pepper is set")
	}
}
