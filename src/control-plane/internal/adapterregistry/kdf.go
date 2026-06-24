/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   kdf.go                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:38:40 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:38:41 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"crypto/aes"
	"crypto/cipher"
	"os"
	"strconv"

	"golang.org/x/crypto/scrypt"
)

// scryptMaxConcurrent sizes the Encryptor.scryptSlots semaphore. Each scrypt
// derivation costs ~128·N·r ≈ 16 MiB (N=16384, r=8); unbounded parallelism under
// bulk mount registration OOM-crashlooped this service (measured 2026-06-11: 17
// restarts under its 48 MiB limit when a 16-way bulk provision hit /databases,
// surfacing as EOF/connection-refused at the caller). Excess derivations queue on
// the semaphore (~tens of ms each) instead of killing the credential store.
// Default 2 → ~32 MiB peak derivation memory.
func scryptMaxConcurrent() int {
	if v, err := strconv.Atoi(os.Getenv("SCRYPT_MAX_CONCURRENT")); err == nil && v > 0 {
		return v
	}
	return 2
}

// deriveKey runs scrypt under the Encryptor's bounded-concurrency semaphore
// (acquire a slot, derive, release on return) — identical acquire/release order
// and bound to the former package-global scryptSlots.
func (e *Encryptor) deriveKey(salt []byte) ([]byte, error) {
	e.scryptSlots <- struct{}{}
	defer func() { <-e.scryptSlots }()
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
