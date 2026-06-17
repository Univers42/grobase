package adapterregistry

import (
	"crypto/aes"
	"crypto/cipher"
	"os"
	"strconv"

	"golang.org/x/crypto/scrypt"
)

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

// gcmForSalt derives the per-record key from the salt and returns an AES-256-GCM
// AEAD with the Node-compatible 16-byte nonce size, shared by Encrypt/Decrypt.
func (e *Encryptor) gcmForSalt(salt []byte) (cipher.AEAD, error) {
	key, err := e.deriveKey(salt)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCMWithNonceSize(block, ivLength)
}
