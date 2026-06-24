/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   envelope.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:21 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:41:23 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package cmek

import (
	"crypto/aes"
	"crypto/cipher"
	"fmt"
)

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
