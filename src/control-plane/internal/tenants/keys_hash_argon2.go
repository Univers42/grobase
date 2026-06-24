/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   keys_hash_argon2.go                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:11 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:12 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"crypto/subtle"
	"os"
	"strconv"

	"golang.org/x/crypto/argon2"
)

// keyHasher mints and verifies API-key hashes. Its slots channel bounds
// CONCURRENT Argon2id computations: each allocates memoryCost (32 MiB), so
// unbounded parallelism under cold-key fan-out OOM-kills the container —
// measured 2026-06-11: a 16-way bulk provision crash-looped tenant-control
// (8 restarts) under its 64 MiB limit, and every in-flight request died as a
// connection EOF. Requests beyond the bound queue on the channel (a verify is
// ~50 ms) instead of killing the identity authority. Sized by
// ARGON2_MAX_CONCURRENT (default 2 → 64 MiB peak hash memory; pair with a
// mem_limit of baseline + slots × 32 MiB). Owning the semaphore on the hasher
// (one per Service) replaces the former package-level singleton with identical
// bounded-concurrency semantics.
type keyHasher struct {
	slots chan struct{}
}

// newKeyHasher builds a hasher with the Argon2 semaphore sized to
// argon2MaxConcurrent() — the same capacity the package singleton used.
func newKeyHasher() *keyHasher {
	return &keyHasher{slots: make(chan struct{}, argon2MaxConcurrent())}
}

func argon2MaxConcurrent() int {
	if v, err := strconv.Atoi(os.Getenv("ARGON2_MAX_CONCURRENT")); err == nil && v > 0 {
		return v
	}
	return 2
}

// hashPayload runs argon2id over (payload || prefix). The prefix doubles as
// the salt so the same payload string yields different hashes per key, but
// we don't need to store a separate salt column. The cost parameters are
// timeCost=1, memoryCost=32*1024 (32 MiB), threads=2, outputLen=32.
func (h *keyHasher) hashPayload(payload, prefix string) string {
	const (
		timeCost   = 1
		memoryCost = 32 * 1024
		threads    = 2
		outputLen  = 32
	)
	h.slots <- struct{}{}
	defer func() { <-h.slots }()
	salt := []byte("mbk-v1-" + prefix)
	sum := argon2.IDKey([]byte(payload), salt, timeCost, memoryCost, threads, outputLen)
	return "argon2id$v=1$m=32768,t=1,p=2$" + b32().EncodeToString(salt) + "$" + b32().EncodeToString(sum)
}

// verifyKeyHash returns true iff the payload+prefix recompute to the stored
// hash. The scheme is detected from the stored hash itself (fast sha256 vs
// legacy argon2id), so a fleet mid-migration verifies both. Constant-time
// compare on the inner bytes.
func (h *keyHasher) verifyKeyHash(payload, prefix, storedHash string) bool {
	var expected string
	if isFastHash(storedHash) {
		expected = hashPayloadFast(payload, prefix)
	} else {
		expected = h.hashPayload(payload, prefix)
	}
	if len(expected) != len(storedHash) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(expected), []byte(storedHash)) == 1
}
