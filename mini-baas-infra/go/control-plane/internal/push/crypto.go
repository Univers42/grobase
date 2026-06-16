package push

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"io"
	"os"
)

// tokenSealer seals/opens a push PROVIDER token (e.g. an FCM server key) with
// AES-256-GCM. The 32-byte key is SHA-256(PUSH_SECRET_KEY) so any sufficiently
// long operator key derives a valid AES-256 key deterministically — the SAME
// fold internal/sso.secretSealer and internal/funcsecrets use. The wire format
// is nonce(12)||ciphertext+tag — a single self-describing blob stored in
// push_subscriptions.token_enc. Decrypting a tampered blob fails (GCM auth tag)
// rather than returning corrupt plaintext.
//
// The webhook channel needs NO provider token; only the 'fcm' channel may carry
// one. A nil sealer (PUSH_SECRET_KEY unset) is therefore tolerated for the
// webhook-only path: sealing an empty token is a no-op and the store keeps
// token_enc NULL. Sealing a NON-empty token without a key is rejected — a
// provider credential must never be stored in clear.
type tokenSealer struct {
	gcm cipher.AEAD
}

// errNoKey guards sealing a non-empty token without a configured key.
var errNoKey = errors.New("push: PUSH_SECRET_KEY not configured (required to store a provider token)")

// newSealerFromEnv builds the sealer from PUSH_SECRET_KEY. An empty key yields a
// nil sealer (valid for the webhook-only path); the seal/open methods are
// nil-safe so the caller never has to branch on it.
func newSealerFromEnv() *tokenSealer {
	return newSealer(os.Getenv("PUSH_SECRET_KEY"))
}

// newSealer derives the AES-256 key from the operator key. An empty key returns
// a nil sealer (not an error) — a webhook-only deployment needs no key.
func newSealer(key string) *tokenSealer {
	if key == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(key))
	block, err := aes.NewCipher(sum[:])
	if err != nil {
		return nil
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil
	}
	return &tokenSealer{gcm: gcm}
}

// seal returns nonce||ciphertext+tag for the plaintext token. An empty token
// seals to nil (the webhook channel: no token at all). A NON-empty token with no
// configured key is rejected — a provider credential must never be stored clear.
func (s *tokenSealer) seal(plaintext string) ([]byte, error) {
	if plaintext == "" {
		return nil, nil
	}
	if s == nil {
		return nil, errNoKey
	}
	nonce := make([]byte, s.gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	return s.gcm.Seal(nonce, nonce, []byte(plaintext), nil), nil
}

// open reverses seal. A nil/short/tampered blob returns an error or empty string
// (for the nil case), never corrupt plaintext. A nil sealer can only open the
// nil blob (no key, no token).
func (s *tokenSealer) open(blob []byte) (string, error) {
	if len(blob) == 0 {
		return "", nil
	}
	if s == nil {
		return "", errNoKey
	}
	ns := s.gcm.NonceSize()
	if len(blob) < ns {
		return "", errors.New("push: sealed token too short")
	}
	nonce, ct := blob[:ns], blob[ns:]
	plain, err := s.gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return "", err
	}
	return string(plain), nil
}
