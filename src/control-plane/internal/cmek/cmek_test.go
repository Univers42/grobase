package cmek

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

const (
	testSeed = "cmek-unit-test-seed"
	keyA     = "tenant-a-kek"
	keyB     = "tenant-b-kek"
)

// TestSealOpenRoundTrip proves the envelope decrypts back to the original
// plaintext through the LocalKMSProvider, and that NEITHER the stored ciphertext
// NOR the wrapped DEK equals the plaintext (no plaintext/DEK at rest).
func TestSealOpenRoundTrip(t *testing.T) {
	ctx := context.Background()
	p := NewLocalKMSProvider(testSeed, keyA)
	plain := []byte("postgresql://user:pass@db.internal:5432/tenant_42?sslmode=require")

	wrapped, iv, ct, err := Seal(ctx, p, keyA, plain)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if len(iv) != nonceLen {
		t.Fatalf("iv length = %d, want %d", len(iv), nonceLen)
	}

	// The stored ciphertext must NOT be (or contain) the plaintext.
	if bytes.Equal(ct, plain) || bytes.Contains(ct, plain) {
		t.Fatal("ciphertext equals/contains the plaintext — encryption did not occur")
	}
	// The wrapped DEK must NOT be the plaintext either.
	if bytes.Contains(wrapped, plain) {
		t.Fatal("wrapped DEK contains the plaintext")
	}

	got, err := Open(ctx, p, keyA, Envelope{Wrapped: wrapped, IV: iv, Ciphertext: ct})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("round trip mismatch: got %q want %q", got, plain)
	}
}

// TestSealNeverStoresDEK proves the wrapped DEK is genuinely wrapped: it differs
// from the plaintext DEK that produced the ciphertext. We can't read the DEK
// directly (Seal zeroes it), but two seals of the same plaintext must produce
// DIFFERENT wrapped DEKs + ciphertexts (fresh DEK + fresh nonce each time).
func TestSealUsesFreshDEKAndNonce(t *testing.T) {
	ctx := context.Background()
	p := NewLocalKMSProvider(testSeed, keyA)
	plain := []byte("same-secret-twice")

	w1, iv1, ct1, err := Seal(ctx, p, keyA, plain)
	if err != nil {
		t.Fatalf("Seal#1: %v", err)
	}
	w2, iv2, ct2, err := Seal(ctx, p, keyA, plain)
	if err != nil {
		t.Fatalf("Seal#2: %v", err)
	}
	if bytes.Equal(iv1, iv2) {
		t.Fatal("two seals produced the same nonce — nonce reuse")
	}
	if bytes.Equal(ct1, ct2) {
		t.Fatal("two seals of the same plaintext produced identical ciphertext — DEK/nonce not fresh")
	}
	if bytes.Equal(w1, w2) {
		t.Fatal("two seals produced the same wrapped DEK — DEK not fresh")
	}
	// Both still decrypt to the same plaintext.
	for i, tc := range []struct {
		w, iv, ct []byte
	}{{w1, iv1, ct1}, {w2, iv2, ct2}} {
		got, err := Open(ctx, p, keyA, Envelope{Wrapped: tc.w, IV: tc.iv, Ciphertext: tc.ct})
		if err != nil {
			t.Fatalf("Open#%d: %v", i, err)
		}
		if !bytes.Equal(got, plain) {
			t.Fatalf("Open#%d mismatch", i)
		}
	}
}

// TestTamperedCiphertextFails proves GCM auth rejects a flipped ciphertext byte.
func TestTamperedCiphertextFails(t *testing.T) {
	ctx := context.Background()
	p := NewLocalKMSProvider(testSeed, keyA)
	wrapped, iv, ct, err := Seal(ctx, p, keyA, []byte("secret-dsn"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	ct[0] ^= 0xFF // flip a ciphertext byte
	if _, err := Open(ctx, p, keyA, Envelope{Wrapped: wrapped, IV: iv, Ciphertext: ct}); err == nil {
		t.Fatal("Open succeeded on a tampered ciphertext — GCM auth not enforced")
	}
}

// TestTamperedNonceFails proves a flipped nonce byte breaks decryption.
func TestTamperedNonceFails(t *testing.T) {
	ctx := context.Background()
	p := NewLocalKMSProvider(testSeed, keyA)
	wrapped, iv, ct, err := Seal(ctx, p, keyA, []byte("secret-dsn"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	iv[0] ^= 0xFF
	if _, err := Open(ctx, p, keyA, Envelope{Wrapped: wrapped, IV: iv, Ciphertext: ct}); err == nil {
		t.Fatal("Open succeeded on a tampered nonce")
	}
}

// TestCryptoShredOnRevoke is the headline: once the KMS key is revoked, Open
// fails permanently and returns ErrShredded — the platform cannot decrypt.
func TestCryptoShredOnRevoke(t *testing.T) {
	ctx := context.Background()
	p := NewLocalKMSProvider(testSeed, keyA)
	plain := []byte("postgresql://shred-me@host/db")

	wrapped, iv, ct, err := Seal(ctx, p, keyA, plain)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	// Sanity: it decrypts BEFORE revocation.
	if _, err := Open(ctx, p, keyA, Envelope{Wrapped: wrapped, IV: iv, Ciphertext: ct}); err != nil {
		t.Fatalf("Open before revoke should succeed: %v", err)
	}

	// CRYPTO-SHRED: delete the KEK from the KMS.
	p.RevokeKey(keyA)

	_, err = Open(ctx, p, keyA, Envelope{Wrapped: wrapped, IV: iv, Ciphertext: ct})
	if err == nil {
		t.Fatal("Open succeeded AFTER the KEK was revoked — data was not crypto-shredded")
	}
	if !errors.Is(err, ErrShredded) {
		t.Fatalf("expected ErrShredded after revoke, got %v", err)
	}
}

// TestWrongKEKFails proves unwrapping under a DIFFERENT key fails (the wrapped
// DEK is bound to its KEK) and surfaces as ErrShredded.
func TestWrongKEKFails(t *testing.T) {
	ctx := context.Background()
	p := NewLocalKMSProvider(testSeed, keyA, keyB)
	wrapped, iv, ct, err := Seal(ctx, p, keyA, []byte("secret"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	// keyB is a valid registered key, but it is NOT the key that wrapped this DEK.
	if _, err := Open(ctx, p, keyB, Envelope{Wrapped: wrapped, IV: iv, Ciphertext: ct}); err == nil {
		t.Fatal("Open succeeded under the wrong KEK — the wrapped DEK is not key-bound")
	} else if !errors.Is(err, ErrShredded) {
		t.Fatalf("wrong-KEK Open should be ErrShredded, got %v", err)
	}
}

// TestSealRejectsBadArgs proves nil provider / empty keyID are rejected.
func TestSealRejectsBadArgs(t *testing.T) {
	ctx := context.Background()
	if _, _, _, err := Seal(ctx, nil, keyA, []byte("x")); err == nil {
		t.Fatal("Seal with nil provider should error")
	}
	p := NewLocalKMSProvider(testSeed, keyA)
	if _, _, _, err := Seal(ctx, p, "", []byte("x")); err == nil {
		t.Fatal("Seal with empty keyID should error")
	}
}

// TestSplitJoinCiphertext proves the column split/join is lossless (the layout
// the adapterregistry store/get path relies on).
func TestSplitJoinCiphertext(t *testing.T) {
	ctx := context.Background()
	p := NewLocalKMSProvider(testSeed, keyA)
	plain := []byte("postgresql://split-join@host/db")

	wrapped, iv, ct, err := Seal(ctx, p, keyA, plain)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	enc, tag, err := SplitCiphertext(ct)
	if err != nil {
		t.Fatalf("SplitCiphertext: %v", err)
	}
	if len(tag) != 16 {
		t.Fatalf("tag length = %d, want 16", len(tag))
	}
	rejoined := JoinCiphertext(enc, tag)
	if !bytes.Equal(rejoined, ct) {
		t.Fatal("JoinCiphertext(SplitCiphertext(ct)) != ct")
	}
	// And the rejoined ciphertext still opens.
	got, err := Open(ctx, p, keyA, Envelope{Wrapped: wrapped, IV: iv, Ciphertext: rejoined})
	if err != nil {
		t.Fatalf("Open on rejoined ct: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatal("rejoined ciphertext did not decrypt to the plaintext")
	}
}
