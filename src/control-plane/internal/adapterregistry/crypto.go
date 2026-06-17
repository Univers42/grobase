package adapterregistry

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"strconv"

	"golang.org/x/crypto/scrypt"
)

// Crypto parameters — must stay byte-identical to the legacy Node CryptoService
// (scryptSync defaults + aes-256-gcm with a 16-byte IV and 16-byte auth tag) so
// records written by the TypeScript service remain decryptable during shadow.
const (
	keyLength   = 32
	ivLength    = 16
	saltLength  = 16
	authTagLen  = 16
	scryptN     = 16384 // Node scryptSync default cost
	scryptR     = 8
	scryptP     = 1
	minKeyChars = 16
)

// EncryptedPayload mirrors the four columns persisted per credential.
type EncryptedPayload struct {
	Encrypted []byte
	IV        []byte
	Tag       []byte
	Salt      []byte
}

// Encryptor derives a per-record key from a master key + salt via scrypt and
// seals plaintext with AES-256-GCM.
type Encryptor struct {
	masterKey []byte
}

// NewEncryptor validates the master key length (matching the Node guard).
func NewEncryptor(masterKey string) (*Encryptor, error) {
	if len(masterKey) < minKeyChars {
		return nil, fmt.Errorf("VAULT_ENC_KEY must be at least %d characters", minKeyChars)
	}
	return &Encryptor{masterKey: []byte(masterKey)}, nil
}

// scryptSlots bounds CONCURRENT scrypt derivations. Each costs ~128·N·r ≈
// 16 MiB (N=16384, r=8); unbounded parallelism under bulk mount registration
// OOM-crashlooped this service (measured 2026-06-11: 17 restarts under its
// 48 MiB limit when a 16-way bulk provision hit /databases, surfacing as
// EOF/connection-refused at the caller). Excess derivations queue here
// (~tens of ms each) instead of killing the credential store. Sized by
// SCRYPT_MAX_CONCURRENT (default 2 → ~32 MiB peak derivation memory).
var scryptSlots = make(chan struct{}, scryptMaxConcurrent())

func scryptMaxConcurrent() int {
	if v, err := strconv.Atoi(os.Getenv("SCRYPT_MAX_CONCURRENT")); err == nil && v > 0 {
		return v
	}
	return 2
}

func (e *Encryptor) deriveKey(salt []byte) ([]byte, error) {
	scryptSlots <- struct{}{}
	defer func() { <-scryptSlots }()
	return scrypt.Key(e.masterKey, salt, scryptN, scryptR, scryptP, keyLength)
}

// Encrypt produces an EncryptedPayload compatible with the Node format:
// ciphertext and tag are stored separately.
func (e *Encryptor) Encrypt(plaintext string) (EncryptedPayload, error) {
	salt := make([]byte, saltLength)
	if _, err := io.ReadFull(rand.Reader, salt); err != nil {
		return EncryptedPayload{}, err
	}
	iv := make([]byte, ivLength)
	if _, err := io.ReadFull(rand.Reader, iv); err != nil {
		return EncryptedPayload{}, err
	}

	key, err := e.deriveKey(salt)
	if err != nil {
		return EncryptedPayload{}, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return EncryptedPayload{}, err
	}
	gcm, err := cipher.NewGCMWithNonceSize(block, ivLength)
	if err != nil {
		return EncryptedPayload{}, err
	}

	// Seal returns ciphertext||tag; split to match the Node column layout.
	sealed := gcm.Seal(nil, iv, []byte(plaintext), nil)
	cut := len(sealed) - authTagLen
	return EncryptedPayload{
		Encrypted: sealed[:cut],
		Tag:       sealed[cut:],
		IV:        iv,
		Salt:      salt,
	}, nil
}

// Decrypt reverses Encrypt and validates payload sizing like the Node service.
func (e *Encryptor) Decrypt(p EncryptedPayload) (string, error) {
	if len(p.IV) != ivLength || len(p.Salt) != saltLength || len(p.Tag) != authTagLen {
		return "", fmt.Errorf("invalid encrypted payload")
	}
	key, err := e.deriveKey(p.Salt)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCMWithNonceSize(block, ivLength)
	if err != nil {
		return "", err
	}

	combined := make([]byte, 0, len(p.Encrypted)+len(p.Tag))
	combined = append(combined, p.Encrypted...)
	combined = append(combined, p.Tag...)

	plain, err := gcm.Open(nil, p.IV, combined, nil)
	if err != nil {
		return "", fmt.Errorf("decrypt failed: %w", err)
	}
	return string(plain), nil
}
