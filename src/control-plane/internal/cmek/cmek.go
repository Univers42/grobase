// Package cmek implements CMEK / BYOK (customer-managed encryption keys) for the
// Grobase control plane (Track-D D4.8). It envelope-encrypts a secret (the
// per-mount external DB connection string) so that the platform stores ONLY a
// wrapped Data-Encryption-Key (DEK) plus DEK-encrypted ciphertext, and CANNOT
// decrypt without asking an EXTERNAL Key-Encryption-Key (KEK) held in a KMS the
// customer controls to UNWRAP the DEK.
//
// The envelope:
//
//	DEK  = a fresh CRYPTO-RANDOM 256-bit key, generated per Seal.
//	ct   = AES-256-GCM(DEK, plaintext) with a random 96-bit nonce (iv).
//	wDEK = KMS.WrapDEK(KEK, DEK)   — the KMS Encrypt of the DEK under the KEK.
//
// The platform persists {wDEK, iv, ct}. The DEK is ZEROED immediately after the
// seal/open. To Open, the platform asks the KMS to UnwrapDEK(KEK, wDEK) -> DEK,
// then AES-GCM-decrypts. If the customer REVOKES/DELETES the KMS KEK, UnwrapDEK
// fails for good and the data is permanently undecryptable — CRYPTO-SHRED.
//
// This package is CONTROL-PLANE ONLY: it never enters the Rust data plane,
// RequestIdentity, the RLS GUCs, or the pool key, so SHARE_POOLS density is
// byte-untouched. It reuses the same AES-256-GCM primitive the adapterregistry
// Encryptor uses for the DEK->ciphertext step (no scrypt: the DEK is already a
// uniformly-random 256-bit key, so a KDF would add nothing).
package cmek

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
)

const (
	// dekLen is the DEK size: 256 bits, matching AES-256.
	dekLen = 32
	// nonceLen is the GCM nonce size: 96 bits, the standard/efficient GCM IV.
	// (The adapterregistry Encryptor uses a 16-byte IV for Node byte-parity; CMEK
	// is a NEW path with no legacy to match, so it uses the GCM default 12 bytes.)
	nonceLen = 12
)

// ErrShredded is returned by Open when the KMS cannot unwrap the DEK — the
// customer revoked/deleted the KEK (crypto-shred) or the wrapped DEK is for a
// different key. The plaintext is unrecoverable. It wraps the underlying KMS
// error so callers can inspect the cause.
var ErrShredded = errors.New("cmek: KMS could not unwrap the DEK (key revoked/deleted or wrong key) — data is crypto-shredded")

// KMSProvider is the external Key-Encryption-Key holder. The platform NEVER
// sees the KEK — it only asks the KMS to Wrap (encrypt) and Unwrap (decrypt) a
// DEK under the KEK named keyID. This is the seam the customer controls: revoke
// keyID at the KMS and every UnwrapDEK for it fails forever.
type KMSProvider interface {
	// WrapDEK asks the KMS to encrypt plaintextDEK under the KEK keyID, returning
	// an opaque wrapped blob. The KMS keeps the KEK; the platform stores only the
	// returned wrapped DEK.
	WrapDEK(ctx context.Context, keyID string, plaintextDEK []byte) (wrapped []byte, err error)
	// UnwrapDEK asks the KMS to decrypt wrappedDEK under the KEK keyID, returning
	// the plaintext DEK. Fails (non-nil error) once keyID is revoked/deleted.
	UnwrapDEK(ctx context.Context, keyID string, wrappedDEK []byte) (plaintext []byte, err error)
}

// Seal envelope-encrypts plaintext under a fresh DEK whose wrapped form is
// produced by provider.WrapDEK(keyID). It returns the wrapped DEK, the GCM
// nonce (iv), and the ciphertext (which already carries the 16-byte GCM auth
// tag appended by Seal). The fresh DEK is ZEROED before return whether or not
// an error occurred.
//
// CMEK reuses the adapterregistry connection_enc/iv/tag columns: callers split
// ciphertext into {connection_enc = ct[:len-16], connection_tag = ct[len-16:]}
// exactly like the inline path, and store wrapped in cmek_wrapped_dek. The
// presence of a non-NULL cmek_wrapped_dek is the mode discriminator.
func Seal(ctx context.Context, provider KMSProvider, keyID string, plaintext []byte) (wrapped, iv, ciphertext []byte, err error) {
	if provider == nil {
		return nil, nil, nil, errors.New("cmek: nil KMSProvider")
	}
	if keyID == "" {
		return nil, nil, nil, errors.New("cmek: empty keyID")
	}

	dek := make([]byte, dekLen)
	defer zero(dek) // never leave a plaintext DEK in memory after the seal.
	if _, err = io.ReadFull(rand.Reader, dek); err != nil {
		return nil, nil, nil, fmt.Errorf("cmek: generate DEK: %w", err)
	}

	nonce := make([]byte, nonceLen)
	if _, err = io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, nil, nil, fmt.Errorf("cmek: generate nonce: %w", err)
	}

	gcm, err := newGCM(dek)
	if err != nil {
		return nil, nil, nil, err
	}
	// Seal returns ciphertext||tag (the tag is the trailing 16 bytes).
	ct := gcm.Seal(nil, nonce, plaintext, nil)

	// Wrap the DEK with the EXTERNAL KEK. The platform never persists the DEK.
	w, err := provider.WrapDEK(ctx, keyID, dek)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("cmek: KMS wrap DEK: %w", err)
	}
	if len(w) == 0 {
		return nil, nil, nil, errors.New("cmek: KMS returned an empty wrapped DEK")
	}
	return w, nonce, ct, nil
}

// Open reverses Seal: it asks provider.UnwrapDEK(keyID, wrapped) for the DEK,
// then AES-256-GCM-decrypts ciphertext (ct||tag) with iv. The DEK is ZEROED
// before return. If the KMS cannot unwrap (revoked/deleted KEK), Open returns
// ErrShredded — the plaintext is permanently unrecoverable.
func Open(ctx context.Context, provider KMSProvider, keyID string, wrapped, iv, ciphertext []byte) ([]byte, error) {
	if provider == nil {
		return nil, errors.New("cmek: nil KMSProvider")
	}
	if keyID == "" {
		return nil, errors.New("cmek: empty keyID")
	}
	if len(iv) != nonceLen {
		return nil, fmt.Errorf("cmek: bad nonce length %d (want %d)", len(iv), nonceLen)
	}

	dek, err := provider.UnwrapDEK(ctx, keyID, wrapped)
	if err != nil {
		// CRYPTO-SHRED: the KEK is gone (or wrong) — the data cannot be decrypted.
		return nil, fmt.Errorf("%w: %v", ErrShredded, err)
	}
	defer zero(dek)
	if len(dek) != dekLen {
		return nil, fmt.Errorf("cmek: KMS returned a %d-byte DEK (want %d)", len(dek), dekLen)
	}

	gcm, err := newGCM(dek)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, iv, ciphertext, nil)
	if err != nil {
		// GCM auth failed: ciphertext/iv/tag tampered, or the DEK is wrong.
		return nil, fmt.Errorf("cmek: GCM open failed (tampered ciphertext or wrong DEK): %w", err)
	}
	return plain, nil
}

// JoinCiphertext re-assembles the GCM ciphertext||tag from the two stored
// columns (connection_enc, connection_tag), the inverse of the SplitCiphertext
// split callers do at store time. Provided so the adapterregistry GetConnection
// path can reconstruct the Open input from its existing column scan without
// re-deriving the layout.
func JoinCiphertext(enc, tag []byte) []byte {
	out := make([]byte, 0, len(enc)+len(tag))
	out = append(out, enc...)
	out = append(out, tag...)
	return out
}

// SplitCiphertext splits the GCM ciphertext||tag Seal returns into the
// {connection_enc, connection_tag} columns the adapterregistry table already
// has (the inline path stores them split, so CMEK matches that layout). The tag
// is the trailing 16 bytes (GCM standard).
func SplitCiphertext(ciphertext []byte) (enc, tag []byte, err error) {
	const tagLen = 16
	if len(ciphertext) < tagLen {
		return nil, nil, fmt.Errorf("cmek: ciphertext too short (%d < %d) to carry a GCM tag", len(ciphertext), tagLen)
	}
	cut := len(ciphertext) - tagLen
	return ciphertext[:cut], ciphertext[cut:], nil
}

// newGCM builds an AES-256-GCM AEAD over the given 32-byte key.
func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("cmek: aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("cmek: gcm: %w", err)
	}
	return gcm, nil
}

// zero overwrites a byte slice in place — best-effort scrub of key material so a
// plaintext DEK does not linger in process memory after use.
func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
