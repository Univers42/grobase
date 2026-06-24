/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   crypto.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:38:26 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:38:27 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"crypto/rand"
	"fmt"
	"io"
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
// seals plaintext with AES-256-GCM. scryptSlots bounds CONCURRENT scrypt
// derivations (see deriveKey); it is allocated once in NewEncryptor with
// capacity scryptMaxConcurrent() and shared by every deriveKey on this
// Encryptor — identical bounded-concurrency to the former package-global.
type Encryptor struct {
	masterKey   []byte
	scryptSlots chan struct{}
}

// NewEncryptor validates the master key length (matching the Node guard) and
// sizes the scrypt concurrency semaphore (SCRYPT_MAX_CONCURRENT, default 2).
func NewEncryptor(masterKey string) (*Encryptor, error) {
	if len(masterKey) < minKeyChars {
		return nil, fmt.Errorf("VAULT_ENC_KEY must be at least %d characters", minKeyChars)
	}
	return &Encryptor{
		masterKey:   []byte(masterKey),
		scryptSlots: make(chan struct{}, scryptMaxConcurrent()),
	}, nil
}

// Encrypt produces an EncryptedPayload compatible with the Node format:
// ciphertext and tag are stored separately. gcm.Seal returns ciphertext||tag,
// which is split here to match the Node column layout.
func (e *Encryptor) Encrypt(plaintext string) (EncryptedPayload, error) {
	salt := make([]byte, saltLength)
	if _, err := io.ReadFull(rand.Reader, salt); err != nil {
		return EncryptedPayload{}, err
	}
	iv := make([]byte, ivLength)
	if _, err := io.ReadFull(rand.Reader, iv); err != nil {
		return EncryptedPayload{}, err
	}
	gcm, err := e.gcmForSalt(salt)
	if err != nil {
		return EncryptedPayload{}, err
	}
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
	gcm, err := e.gcmForSalt(p.Salt)
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
