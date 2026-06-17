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
// error so callers can inspect the cause. (Type cmekErr lives in errors.go.)
const ErrShredded cmekErr = "cmek: KMS could not unwrap the DEK (key revoked/deleted or wrong key) — data is crypto-shredded"

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
// tag appended by gcm.Seal — the tag is the trailing 16 bytes). The fresh DEK
// is ZEROED before return whether or not an error occurred, so a plaintext DEK
// never lingers in process memory after the seal. The DEK is wrapped with the
// EXTERNAL KEK and the platform never persists the DEK itself.
//
// CMEK reuses the adapterregistry connection_enc/iv/tag columns: callers split
// ciphertext into {connection_enc = ct[:len-16], connection_tag = ct[len-16:]}
// exactly like the inline path, and store wrapped in cmek_wrapped_dek. The
// presence of a non-NULL cmek_wrapped_dek is the mode discriminator.
func Seal(ctx context.Context, provider KMSProvider, keyID string, plaintext []byte) (wrapped, iv, ciphertext []byte, err error) {
	if err = validateArgs(provider, keyID); err != nil {
		return nil, nil, nil, err
	}
	dek, nonce, err := genDEKAndNonce()
	if err != nil {
		return nil, nil, nil, err
	}
	defer zero(dek)
	gcm, err := newGCM(dek)
	if err != nil {
		return nil, nil, nil, err
	}
	ct := gcm.Seal(nil, nonce, plaintext, nil)
	w, err := provider.WrapDEK(ctx, keyID, dek)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("cmek: KMS wrap DEK: %w", err)
	}
	if len(w) == 0 {
		return nil, nil, nil, errors.New("cmek: KMS returned an empty wrapped DEK")
	}
	return w, nonce, ct, nil
}

// validateArgs rejects a nil provider or empty keyID — the guard shared by Seal
// and Open.
func validateArgs(provider KMSProvider, keyID string) error {
	if provider == nil {
		return errors.New("cmek: nil KMSProvider")
	}
	if keyID == "" {
		return errors.New("cmek: empty keyID")
	}
	return nil
}

// genDEKAndNonce returns a fresh crypto-random 256-bit DEK and a 96-bit GCM
// nonce. The caller owns zeroing the DEK after use.
func genDEKAndNonce() (dek, nonce []byte, err error) {
	dek = make([]byte, dekLen)
	if _, err = io.ReadFull(rand.Reader, dek); err != nil {
		return nil, nil, fmt.Errorf("cmek: generate DEK: %w", err)
	}
	nonce = make([]byte, nonceLen)
	if _, err = io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, nil, fmt.Errorf("cmek: generate nonce: %w", err)
	}
	return dek, nonce, nil
}

// Envelope is the persisted CMEK envelope — exactly the three values Seal
// produces ({wrapped DEK, GCM nonce, ciphertext||tag}) and Open consumes.
// Grouping them keeps Open to a key reference + the envelope instead of a flat
// six-arg list.
type Envelope struct {
	Wrapped    []byte
	IV         []byte
	Ciphertext []byte
}

// Open reverses Seal: it asks provider.UnwrapDEK(keyID, env.Wrapped) for the
// DEK, then AES-256-GCM-decrypts env.Ciphertext (ct||tag) with env.IV. The DEK
// is ZEROED before return. If the KMS cannot unwrap (revoked/deleted KEK), Open
// returns ErrShredded — the plaintext is permanently unrecoverable. If the
// GCM auth check fails instead (ciphertext/iv/tag tampered, or the DEK is
// wrong), Open returns a wrapped GCM-open error rather than ErrShredded.
func Open(ctx context.Context, provider KMSProvider, keyID string, env Envelope) ([]byte, error) {
	if err := validateArgs(provider, keyID); err != nil {
		return nil, err
	}
	if len(env.IV) != nonceLen {
		return nil, fmt.Errorf("cmek: bad nonce length %d (want %d)", len(env.IV), nonceLen)
	}
	dek, err := unwrapDEK(ctx, provider, keyID, env.Wrapped)
	if err != nil {
		return nil, err
	}
	defer zero(dek)
	gcm, err := newGCM(dek)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, env.IV, env.Ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("cmek: GCM open failed (tampered ciphertext or wrong DEK): %w", err)
	}
	return plain, nil
}

// unwrapDEK asks the KMS to unwrap the DEK and validates its length. A KMS
// failure means the KEK is gone or wrong (revoked/deleted), so the data can no
// longer be decrypted: it maps to ErrShredded — the crypto-shred path.
func unwrapDEK(ctx context.Context, provider KMSProvider, keyID string, wrapped []byte) ([]byte, error) {
	dek, err := provider.UnwrapDEK(ctx, keyID, wrapped)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrShredded, err)
	}
	if len(dek) != dekLen {
		zero(dek)
		return nil, fmt.Errorf("cmek: KMS returned a %d-byte DEK (want %d)", len(dek), dekLen)
	}
	return dek, nil
}
