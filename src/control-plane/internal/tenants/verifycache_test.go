/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   verifycache_test.go                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:13 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"testing"
	"time"
)

func testCache(ttl time.Duration, max int) *verifyCache {
	return &verifyCache{
		m:   make(map[string]verifyCacheEntry),
		ttl: ttl,
		max: max,
		now: time.Now,
	}
}

func TestVerifyCacheHitSkipsAfterPut(t *testing.T) {
	c := testCache(time.Minute, 16)
	h := keyHash("mbk_abcabcabcabc_payloadpayloadpayloadxx")
	if _, ok := c.get(h); ok {
		t.Fatal("empty cache must miss")
	}
	want := VerifyKeyResponse{Valid: true, TenantID: "acme", KeyID: "k1", Scopes: []string{"read"}}
	c.put(h, want)
	got, ok := c.get(h)
	if !ok {
		t.Fatal("expected hit after put")
	}
	if got.TenantID != "acme" || got.KeyID != "k1" {
		t.Fatalf("wrong cached value: %+v", got)
	}
}

func TestVerifyCacheNeverCachesInvalid(t *testing.T) {
	c := testCache(time.Minute, 16)
	h := keyHash("mbk_xxxxxxxxxxxx_nope")
	c.put(h, VerifyKeyResponse{Valid: false, Reason: "no_match"})
	if _, ok := c.get(h); ok {
		t.Fatal("invalid results must not be cached")
	}
}

func TestVerifyCacheRespectsTTL(t *testing.T) {
	now := time.Unix(0, 0)
	c := testCache(time.Second, 16)
	c.now = func() time.Time { return now }
	h := keyHash("mbk_ttlttlttlttl_payloadpayloadpayloadxx")
	c.put(h, VerifyKeyResponse{Valid: true, TenantID: "t"})
	if _, ok := c.get(h); !ok {
		t.Fatal("fresh entry must hit")
	}
	now = now.Add(2 * time.Second) // past TTL
	if _, ok := c.get(h); ok {
		t.Fatal("expired entry must miss")
	}
}

func TestVerifyCacheDisabledWhenTTLZero(t *testing.T) {
	c := testCache(0, 16)
	if c.enabled() {
		t.Fatal("ttl=0 must disable")
	}
	h := keyHash("mbk_zzzzzzzzzzzz_payloadpayloadpayloadxx")
	c.put(h, VerifyKeyResponse{Valid: true, TenantID: "t"})
	if _, ok := c.get(h); ok {
		t.Fatal("disabled cache must always miss")
	}
}

func TestVerifyCacheFlushClearsAll(t *testing.T) {
	c := testCache(time.Minute, 16)
	h := keyHash("mbk_flushflushfl_payloadpayloadpayloadxx")
	c.put(h, VerifyKeyResponse{Valid: true, TenantID: "t"})
	c.flush()
	if _, ok := c.get(h); ok {
		t.Fatal("flush must drop all entries")
	}
}

func TestVerifyCacheEvictsAtCapacity(t *testing.T) {
	c := testCache(time.Minute, 2)
	for i, k := range []string{"a", "b", "c"} {
		c.put(keyHash(k), VerifyKeyResponse{Valid: true, TenantID: k})
		_ = i
	}
	// max=2: after inserting 3 distinct keys the map never exceeds the cap.
	c.mu.RLock()
	n := len(c.m)
	c.mu.RUnlock()
	if n > 2 {
		t.Fatalf("cache exceeded max: %d", n)
	}
}

func TestKeyHashIsStableAndOpaque(t *testing.T) {
	full := "mbk_abcabcabcabc_payloadpayloadpayloadxx"
	h1, h2 := keyHash(full), keyHash(full)
	if h1 != h2 {
		t.Fatal("hash must be deterministic")
	}
	if len(h1) != 64 {
		t.Fatalf("expected 64 hex chars, got %d", len(h1))
	}
	if h1 == full {
		t.Fatal("hash must not equal cleartext")
	}
}
