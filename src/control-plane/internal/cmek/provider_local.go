/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   provider_local.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:29 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:41:30 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package cmek

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"io"
)

// LocalKMSProvider is a TEST-ONLY KMS: it wraps/unwraps the DEK with a fixed
// in-process AES-256 KEK. It exists so the cmek unit tests can prove the
// envelope round-trip and crypto-shred semantics WITHOUT a running Vault. It is
// NOT a real KMS — the KEK lives in this process's memory, which defeats the
// whole "we never hold your unwrap key" property. Never construct it outside
// tests / local development; production must use VaultTransitProvider (or another
// external KMSProvider).
//
// Wrap  = AES-256-GCM(KEK, DEK) with a random nonce; wrapped = nonce||ct.
// Unwrap inverts it; a wrong/zeroed KEK fails GCM auth (the crypto-shred analog).
type LocalKMSProvider struct {
	keks map[string][]byte // keyID -> 32-byte KEK (test only)
}

// NewLocalKMSProvider derives a deterministic 256-bit KEK per keyID from a test
// seed (sha256(seed||keyID)), so a test can wrap under one keyID and prove that
// unwrapping under a DIFFERENT keyID (or a revoked one) fails. TEST-ONLY.
func NewLocalKMSProvider(seed string, keyIDs ...string) *LocalKMSProvider {
	p := &LocalKMSProvider{keks: map[string][]byte{}}
	for _, id := range keyIDs {
		p.keks[id] = deriveTestKEK(seed, id)
	}
	return p
}

// RevokeKey deletes a keyID's KEK from this test provider, so subsequent
// UnwrapDEK calls fail — the in-process analog of `vault delete transit/keys/x`
// (crypto-shred). TEST-ONLY.
func (p *LocalKMSProvider) RevokeKey(keyID string) { delete(p.keks, keyID) }

func deriveTestKEK(seed, keyID string) []byte {
	h := sha256.Sum256([]byte("cmek-local-test-kek\x00" + seed + "\x00" + keyID))
	return h[:]
}

// WrapDEK AES-256-GCM-encrypts the DEK under the keyID's KEK; wrapped = nonce||ct.
func (p *LocalKMSProvider) WrapDEK(_ context.Context, keyID string, plaintextDEK []byte) ([]byte, error) {
	kek, ok := p.keks[keyID]
	if !ok {
		return nil, fmt.Errorf("cmek/local: unknown keyID %q (test KEK not registered)", keyID)
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	ct := gcm.Seal(nil, nonce, plaintextDEK, nil)
	return append(nonce, ct...), nil
}

// UnwrapDEK reverses WrapDEK. A missing keyID (revoked) or a wrong KEK fails —
// the test crypto-shred path.
func (p *LocalKMSProvider) UnwrapDEK(_ context.Context, keyID string, wrappedDEK []byte) ([]byte, error) {
	kek, ok := p.keks[keyID]
	if !ok {
		return nil, fmt.Errorf("cmek/local: keyID %q revoked/unknown — cannot unwrap (crypto-shred)", keyID)
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	if len(wrappedDEK) < ns {
		return nil, fmt.Errorf("cmek/local: wrapped DEK too short")
	}
	nonce, ct := wrappedDEK[:ns], wrappedDEK[ns:]
	dek, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("cmek/local: unwrap GCM open failed (wrong KEK / tampered): %w", err)
	}
	return dek, nil
}
