package sso

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"io"
	"os"
)

// secretSealer seals/opens the OIDC client secret with AES-256-GCM. The 32-byte
// key is SHA-256(SSO_SECRET_KEY) so any sufficiently-long operator key derives a
// valid AES-256 key deterministically (the same fold internal/funcsecrets uses
// for its env-key path). The wire format is nonce(12) || ciphertext+tag — a
// single self-describing blob stored in sso_connections.client_secret_enc, the
// minimal clearly-marked AES-GCM the slice calls for when no shared crypto helper
// is wired in. Decrypting a tampered blob fails (GCM auth tag) rather than
// returning corrupt plaintext.
type secretSealer struct {
	gcm cipher.AEAD
}

// NewSecretSealerFromEnv builds the sealer from SSO_SECRET_KEY (the env-key path,
// mirroring export.NewStoreFromEnv). main.go calls this only along the opt-in
// SSO_ENABLED path; an unset/empty key fails fast (a connection's secret must be
// sealed, never stored in clear) — same fail-fast discipline as the export store.
func NewSecretSealerFromEnv() (*secretSealer, error) {
	return newSecretSealer(os.Getenv("SSO_SECRET_KEY"))
}

// newSecretSealer derives the AES-256 key from the operator key. An empty key is
// rejected (a connection's secret must be sealed, never stored in clear).
func newSecretSealer(key string) (*secretSealer, error) {
	if key == "" {
		return nil, errNoKey
	}
	sum := sha256.Sum256([]byte(key))
	block, err := aes.NewCipher(sum[:])
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &secretSealer{gcm: gcm}, nil
}

// seal returns nonce||ciphertext+tag for the plaintext secret. An empty secret
// seals to nil (a public client with no secret is valid for some IdPs).
func (s *secretSealer) seal(plaintext string) ([]byte, error) {
	if plaintext == "" {
		return nil, nil
	}
	nonce := make([]byte, s.gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	return s.gcm.Seal(nonce, nonce, []byte(plaintext), nil), nil
}

// open reverses seal. A nil/short/tampered blob returns an error or empty string
// (for the nil case), never corrupt plaintext.
func (s *secretSealer) open(blob []byte) (string, error) {
	if len(blob) == 0 {
		return "", nil
	}
	ns := s.gcm.NonceSize()
	if len(blob) < ns {
		return "", errors.New("sso: sealed secret too short")
	}
	nonce, ct := blob[:ns], blob[ns:]
	plain, err := s.gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return "", err
	}
	return string(plain), nil
}
