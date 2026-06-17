package tenants

import (
	"strings"
	"testing"
)

// TestGenerateKeyRoundTrip proves a freshly minted key parses back into the
// SAME (prefix, payload) it was built from, the full key carries the header, and
// the prefix length matches prefixLen. A key that did not round-trip would be
// unverifiable the instant it is issued.
func TestGenerateKeyRoundTrip(t *testing.T) {
	for i := 0; i < 200; i++ {
		prefix, full, hash, err := generateKey()
		if err != nil {
			t.Fatalf("generateKey: %v", err)
		}
		if !strings.HasPrefix(full, keyHeader) {
			t.Fatalf("full key %q missing header %q", full, keyHeader)
		}
		if len(prefix) != prefixLen {
			t.Fatalf("prefix %q len=%d, want %d", prefix, len(prefix), prefixLen)
		}
		if hash == "" {
			t.Fatal("hash must not be empty")
		}
		gotPrefix, gotPayload, perr := parseKey(full)
		if perr != nil {
			t.Fatalf("parseKey(%q) of a freshly generated key failed: %v", full, perr)
		}
		if gotPrefix != prefix {
			t.Fatalf("round-trip prefix mismatch: parsed %q, generated %q", gotPrefix, prefix)
		}
		// The hash recorded at mint time must verify against the parsed payload.
		if !verifyKeyHash(gotPayload, gotPrefix, hash) {
			t.Fatalf("minted hash does not verify for its own key (prefix=%q)", gotPrefix)
		}
	}
}

// TestGenerateKeyPrefixesUnique proves prefixes do not collide across many mints
// (the prefix is the cleartext lookup key — a collision would conflate two
// tenants' keys at lookup time).
func TestGenerateKeyPrefixesUnique(t *testing.T) {
	const n = 5000
	seen := make(map[string]struct{}, n)
	for i := 0; i < n; i++ {
		prefix, _, _, err := generateKey()
		if err != nil {
			t.Fatalf("generateKey: %v", err)
		}
		if _, dup := seen[prefix]; dup {
			t.Fatalf("prefix collision after %d mints: %q", i, prefix)
		}
		seen[prefix] = struct{}{}
	}
}

// TestGenerateKeyDefaultIsFastHash proves the DEFAULT mint scheme is the fast
// SHA-256 scheme (the documented, intentional default), not legacy argon2id.
func TestGenerateKeyDefaultIsFastHash(t *testing.T) {
	t.Setenv("KEY_HASH_LEGACY_ARGON2", "")
	t.Setenv("KEY_HASH_PEPPER", "")
	_, _, hash, err := generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	if !isFastHash(hash) {
		t.Fatalf("default mint must use the fast scheme, got %q", hash)
	}
	if !strings.HasPrefix(hash, fastHashTag) {
		t.Fatalf("fast hash must carry tag %q, got %q", fastHashTag, hash)
	}
}

// TestParseKeyMalformed is the core hardening table: a large battery of
// malformed / weird inputs MUST ALL return errInvalidFormat (never a partial
// parse, never a panic). Each vector is a subtest so it counts individually.
func TestParseKeyMalformed(t *testing.T) {
	const goodPrefix = "abcdefghijkl"          // 12 chars
	const goodPayload = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 32 chars

	bad := []struct {
		name string
		in   string
	}{
		{"empty", ""},
		{"only_header", "mbk_"},
		{"header_only_no_underscore", "mbk_" + goodPrefix},
		{"no_header", goodPrefix + "_" + goodPayload},
		{"wrong_header_pbk", "pbk_" + goodPrefix + "_" + goodPayload},
		{"wrong_header_caps", "MBK_" + goodPrefix + "_" + goodPayload},
		{"header_with_space", "mbk _" + goodPrefix + "_" + goodPayload},
		{"no_underscore_at_all", "mbk" + goodPrefix + goodPayload},
		{"prefix_too_short_11", "mbk_" + "abcdefghijk" + "_" + goodPayload},
		{"prefix_too_long_13", "mbk_" + "abcdefghijklm" + "_" + goodPayload},
		{"prefix_empty", "mbk__" + goodPayload},
		{"payload_too_short_15", "mbk_" + goodPrefix + "_" + strings.Repeat("a", 15)},
		{"payload_empty", "mbk_" + goodPrefix + "_"},
		{"payload_too_long_65", "mbk_" + goodPrefix + "_" + strings.Repeat("a", 65)},
		{"payload_way_too_long", "mbk_" + goodPrefix + "_" + strings.Repeat("a", 4096)},
		{"only_underscore", "mbk__"},
		{"leading_space", " mbk_" + goodPrefix + "_" + goodPayload},
		// A trailing space pushes the payload to 33 chars (still 16..64), so the
		// structural parse accepts it — the *charset* is enforced at MINT, not
		// parse. A unicode byte in the PREFIX makes parts[0] != 12 bytes, which IS
		// a structural reject (multi-byte rune > 1 byte ⇒ wrong length).
		{"unicode_header", "ｍbk_" + goodPrefix + "_" + goodPayload},
		{"unicode_in_prefix", "mbk_abcdéfghij_" + goodPayload}, // é is 2 bytes ⇒ prefix byte-len 13
		{"only_spaces", "          "},
		{"header_repeated_short_prefix", "mbk_mbk_" + goodPayload}, // prefix "mbk"=3 bytes
		{"just_underscores", "________________"},
		// "mbk_abcd_efghij_<payload>": SplitN on first "_" gives prefix "abcd"
		// (4 bytes != 12) ⇒ structural reject.
		{"prefix_with_underscore", "mbk_abcd_efghij_" + goodPayload},
	}
	for _, c := range bad {
		t.Run(c.name, func(t *testing.T) {
			_, _, err := parseKey(c.in)
			if err != errInvalidFormat {
				t.Fatalf("parseKey(%q) = %v, want errInvalidFormat", c.in, err)
			}
		})
	}
}

// TestParseKeyValid proves well-formed keys (boundary payload lengths included)
// parse cleanly into the expected components.
func TestParseKeyValid(t *testing.T) {
	const goodPrefix = "abcdefghijkl"
	cases := []struct {
		name    string
		payload string
	}{
		{"min_payload_16", strings.Repeat("a", 16)},
		{"typical_payload_32", strings.Repeat("b", 32)},
		{"max_payload_64", strings.Repeat("c", 64)},
		{"payload_with_digits", "abc123def456ghi789jkl012"},
		// SplitN(_,2) keeps a later underscore inside the payload — still valid shape.
		{"payload_contains_underscore", "aaaa_bbbb_cccc_dddd"},
		// parseKey is STRUCTURAL-only (length-bounded): the payload CHARSET is
		// enforced at MINT (generateKey), not at parse. So a length-valid payload
		// with weird bytes still parses — verifyKeyHash is the real gate that then
		// rejects it (no stored hash will match). Documenting that boundary here.
		{"weird_chars_len_valid", "'; DROP TABLE keys; SELECT *"},
		{"nul_byte_len_valid", "aaaaaaaaaa\x00aaaaaaaaaaaaaaaaaaaaa"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			full := keyHeader + goodPrefix + "_" + c.payload
			pfx, pl, err := parseKey(full)
			if err != nil {
				t.Fatalf("parseKey(%q) unexpected error: %v", full, err)
			}
			if pfx != goodPrefix {
				t.Fatalf("prefix = %q, want %q", pfx, goodPrefix)
			}
			if pl != c.payload {
				t.Fatalf("payload = %q, want %q", pl, c.payload)
			}
		})
	}
}

// TestHashFastDeterministicAndTagged proves the fast hash is deterministic
// (same input → same output) and carries the scheme tag; different prefix or
// different payload yields a different hash (the per-key salt actually varies).
func TestHashFastDeterministicAndTagged(t *testing.T) {
	t.Setenv("KEY_HASH_PEPPER", "")
	h1 := hashPayloadFast("payload-x", "prefixaaaaaa")
	h2 := hashPayloadFast("payload-x", "prefixaaaaaa")
	if h1 != h2 {
		t.Fatalf("fast hash not deterministic: %q != %q", h1, h2)
	}
	if !strings.HasPrefix(h1, fastHashTag) {
		t.Fatalf("fast hash missing tag: %q", h1)
	}
	if !isFastHash(h1) {
		t.Fatal("isFastHash must report true for a fast hash")
	}
	// Different payload → different hash.
	if hashPayloadFast("payload-y", "prefixaaaaaa") == h1 {
		t.Fatal("different payload must change the fast hash")
	}
	// Different prefix (salt) → different hash for the same payload.
	if hashPayloadFast("payload-x", "prefixbbbbbb") == h1 {
		t.Fatal("different prefix (salt) must change the fast hash")
	}
}

// TestHashFastPepperChangesHash proves KEY_HASH_PEPPER switches to the HMAC path
// deterministically: WITH a pepper the hash differs from the no-pepper hash, two
// runs with the same pepper agree, and a different pepper yields a different hash.
func TestHashFastPepperChangesHash(t *testing.T) {
	t.Setenv("KEY_HASH_PEPPER", "")
	plain := hashPayloadFast("p", "prefixaaaaaa")

	t.Setenv("KEY_HASH_PEPPER", "secret-pepper-1")
	peppered := hashPayloadFast("p", "prefixaaaaaa")
	peppered2 := hashPayloadFast("p", "prefixaaaaaa")
	if peppered != peppered2 {
		t.Fatal("HMAC path must be deterministic for the same pepper")
	}
	if peppered == plain {
		t.Fatal("a pepper must change the hash (HMAC path not taken)")
	}
	if !isFastHash(peppered) {
		t.Fatal("peppered hash must still be a fast-scheme hash")
	}

	t.Setenv("KEY_HASH_PEPPER", "secret-pepper-2")
	peppered3 := hashPayloadFast("p", "prefixaaaaaa")
	if peppered3 == peppered {
		t.Fatal("a different pepper must produce a different hash")
	}
}

// TestSelectHashRespectsLegacyFlag proves KEY_HASH_LEGACY_ARGON2=1 selects the
// argon2id scheme (NOT the fast scheme), and otherwise the fast scheme is used.
func TestSelectHashRespectsLegacyFlag(t *testing.T) {
	t.Setenv("KEY_HASH_PEPPER", "")

	t.Setenv("KEY_HASH_LEGACY_ARGON2", "1")
	legacy := selectHash("payload-z", "prefixaaaaaa")
	if isFastHash(legacy) {
		t.Fatalf("KEY_HASH_LEGACY_ARGON2=1 must mint an argon2id hash, got fast: %q", legacy)
	}
	if !strings.HasPrefix(legacy, "argon2id$") {
		t.Fatalf("legacy hash must carry argon2id tag, got %q", legacy)
	}

	t.Setenv("KEY_HASH_LEGACY_ARGON2", "")
	fast := selectHash("payload-z", "prefixaaaaaa")
	if !isFastHash(fast) {
		t.Fatalf("default selectHash must be fast, got %q", fast)
	}
	// Any value other than exactly "1" stays on the fast scheme.
	t.Setenv("KEY_HASH_LEGACY_ARGON2", "true")
	if !isFastHash(selectHash("payload-z", "prefixaaaaaa")) {
		t.Fatal("KEY_HASH_LEGACY_ARGON2 must be the literal '1' to flip; 'true' must stay fast")
	}
}

// TestHashPayloadArgon2Deterministic proves the legacy argon2id hash is also
// deterministic and salt-varying (the verify path round-trips through it).
func TestHashPayloadArgon2Deterministic(t *testing.T) {
	h1 := hashPayload("payload-a", "prefixaaaaaa")
	h2 := hashPayload("payload-a", "prefixaaaaaa")
	if h1 != h2 {
		t.Fatalf("argon2id hash not deterministic: %q != %q", h1, h2)
	}
	if isFastHash(h1) {
		t.Fatalf("argon2id hash must not be flagged fast: %q", h1)
	}
	if hashPayload("payload-b", "prefixaaaaaa") == h1 {
		t.Fatal("different payload must change the argon2id hash")
	}
	if hashPayload("payload-a", "prefixbbbbbb") == h1 {
		t.Fatal("different prefix (salt) must change the argon2id hash")
	}
}

// TestVerifyKeyHashFastRoundTrip proves verifyKeyHash accepts the matching
// (payload, prefix, fastHash) triple and rejects every tampered variant.
func TestVerifyKeyHashFastRoundTrip(t *testing.T) {
	t.Setenv("KEY_HASH_PEPPER", "")
	const payload = "the-real-payload-1234"
	const prefix = "prefixaaaaaa"
	stored := hashPayloadFast(payload, prefix)

	if !verifyKeyHash(payload, prefix, stored) {
		t.Fatal("matching triple must verify true (fast)")
	}
	t.Run("wrong_payload", func(t *testing.T) {
		if verifyKeyHash("the-real-payload-1235", prefix, stored) {
			t.Fatal("wrong payload must NOT verify")
		}
	})
	t.Run("wrong_prefix", func(t *testing.T) {
		if verifyKeyHash(payload, "prefixbbbbbb", stored) {
			t.Fatal("wrong prefix (salt) must NOT verify")
		}
	})
	t.Run("empty_stored", func(t *testing.T) {
		if verifyKeyHash(payload, prefix, "") {
			t.Fatal("empty stored hash must NOT verify")
		}
	})
	t.Run("length_mismatch_stored", func(t *testing.T) {
		if verifyKeyHash(payload, prefix, stored+"AB") {
			t.Fatal("length-mismatched stored hash must NOT verify")
		}
		if verifyKeyHash(payload, prefix, stored[:len(stored)-2]) {
			t.Fatal("truncated stored hash must NOT verify")
		}
	})
	t.Run("single_char_tamper", func(t *testing.T) {
		b := []byte(stored)
		// flip a byte near the end (inside the hash body) without changing length
		last := len(b) - 1
		if b[last] == 'A' {
			b[last] = 'B'
		} else {
			b[last] = 'A'
		}
		if verifyKeyHash(payload, prefix, string(b)) {
			t.Fatal("single-char-tampered stored hash must NOT verify")
		}
	})
}

// TestVerifyKeyHashLegacyRoundTrip proves verifyKeyHash also accepts a legacy
// argon2id stored hash (mid-migration parity) and rejects tampered variants —
// scheme is detected from the stored hash itself.
func TestVerifyKeyHashLegacyRoundTrip(t *testing.T) {
	const payload = "legacy-payload-9876"
	const prefix = "prefixcccccc"
	stored := hashPayload(payload, prefix)

	if isFastHash(stored) {
		t.Fatal("precondition: legacy hash must not be flagged fast")
	}
	if !verifyKeyHash(payload, prefix, stored) {
		t.Fatal("matching triple must verify true (legacy argon2id)")
	}
	if verifyKeyHash("legacy-payload-9877", prefix, stored) {
		t.Fatal("wrong payload must NOT verify (legacy)")
	}
	if verifyKeyHash(payload, "prefixdddddd", stored) {
		t.Fatal("wrong prefix must NOT verify (legacy)")
	}
	// single-char tamper on the legacy hash body (same length, different content)
	var tampered string
	if stored[len(stored)-1] == 'A' {
		tampered = stored[:len(stored)-1] + "B"
	} else {
		tampered = stored[:len(stored)-1] + "A"
	}
	if verifyKeyHash(payload, prefix, tampered) {
		t.Fatal("tampered legacy hash must NOT verify")
	}
}

// TestVerifyKeyHashCrossSchemeRejected proves a fast stored hash is NOT verified
// by recomputing argon2 (and vice versa) — the stored tag steers the recompute,
// so an attacker cannot downgrade-confuse the verifier into the wrong scheme.
func TestVerifyKeyHashCrossSchemeRejected(t *testing.T) {
	t.Setenv("KEY_HASH_PEPPER", "")
	const payload = "x-payload"
	const prefix = "prefixeeeeee"
	fast := hashPayloadFast(payload, prefix)
	legacy := hashPayload(payload, prefix)

	// Each verifies against ITS OWN scheme.
	if !verifyKeyHash(payload, prefix, fast) {
		t.Fatal("fast stored hash must verify via fast recompute")
	}
	if !verifyKeyHash(payload, prefix, legacy) {
		t.Fatal("legacy stored hash must verify via argon2 recompute")
	}
	// A fast and legacy hash of the SAME input are different strings.
	if fast == legacy {
		t.Fatal("fast and legacy hashes of the same input must differ")
	}
}

// TestVerifyKeyHashPepperedRoundTrip proves verify works when KEY_HASH_PEPPER is
// set at BOTH mint and verify (HMAC path), and FAILS when the pepper changes
// between mint and verify (a stolen DB without the pepper cannot verify keys).
func TestVerifyKeyHashPepperedRoundTrip(t *testing.T) {
	const payload = "peppered-payload"
	const prefix = "prefixffffff"

	t.Setenv("KEY_HASH_PEPPER", "pepper-A")
	stored := hashPayloadFast(payload, prefix)
	if !verifyKeyHash(payload, prefix, stored) {
		t.Fatal("peppered hash must verify with the same pepper")
	}

	t.Setenv("KEY_HASH_PEPPER", "pepper-B")
	if verifyKeyHash(payload, prefix, stored) {
		t.Fatal("a stored hash made with pepper-A must NOT verify under pepper-B")
	}

	t.Setenv("KEY_HASH_PEPPER", "")
	if verifyKeyHash(payload, prefix, stored) {
		t.Fatal("a peppered stored hash must NOT verify with NO pepper (stolen-DB defense)")
	}
}
