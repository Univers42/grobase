/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   jwks.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:01 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:02 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// jwksKeyset fetches + caches RSA public keys from a JWKS endpoint (RFC 7517),
// keyed by `kid`, for RS256 verification (audit O2). It refreshes on an unknown
// kid (key rotation) but no more than once per minRefreshInterval, so a token
// with a bogus kid can't be used to hammer the JWKS URL. Verify-only: the
// control plane never holds a private key.
type jwksKeyset struct {
	url                string
	client             *http.Client
	minRefreshInterval time.Duration

	mu          sync.RWMutex
	keys        map[string]*rsa.PublicKey
	lastRefresh time.Time
}

func newJwksKeyset(url string) *jwksKeyset {
	return &jwksKeyset{
		url:                url,
		client:             &http.Client{Timeout: 5 * time.Second},
		minRefreshInterval: time.Minute,
		keys:               map[string]*rsa.PublicKey{},
	}
}

// publicKey returns the RSA public key for kid, refreshing the JWKS once if the
// kid is unknown (and the refresh window has elapsed). An empty kid is allowed
// only when the set holds exactly one key (a common single-key deployment).
func (k *jwksKeyset) publicKey(kid string) (*rsa.PublicKey, error) {
	if key := k.lookup(kid); key != nil {
		return key, nil
	}
	k.mu.Lock()
	stale := time.Since(k.lastRefresh) >= k.minRefreshInterval
	k.mu.Unlock()
	if stale {
		if err := k.refresh(); err != nil {
			return nil, fmt.Errorf("jwks refresh: %w", err)
		}
	}
	if key := k.lookup(kid); key != nil {
		return key, nil
	}
	return nil, fmt.Errorf("no JWKS key for kid %q", kid)
}

func (k *jwksKeyset) lookup(kid string) *rsa.PublicKey {
	k.mu.RLock()
	defer k.mu.RUnlock()
	if kid == "" && len(k.keys) == 1 {
		for _, v := range k.keys {
			return v
		}
	}
	return k.keys[kid]
}

func (k *jwksKeyset) refresh() error {
	resp, err := k.client.Get(k.url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	var doc jwksDoc
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return err
	}
	parsed := parseJWKKeys(doc)
	if len(parsed) == 0 {
		return errors.New("no usable RSA signing keys in JWKS")
	}
	k.mu.Lock()
	k.keys = parsed
	k.lastRefresh = time.Now()
	k.mu.Unlock()
	return nil
}

// parseJWKKeys builds the kid→RSA-public-key map from a JWKS doc, skipping
// non-RSA / non-signing / malformed entries (keeping the rest).
func parseJWKKeys(doc jwksDoc) map[string]*rsa.PublicKey {
	parsed := map[string]*rsa.PublicKey{}
	for _, jwk := range doc.Keys {
		if jwk.Kty != "RSA" || (jwk.Use != "" && jwk.Use != "sig") {
			continue
		}
		pub, err := rsaPublicKeyFromJWK(jwk.N, jwk.E)
		if err != nil {
			continue
		}
		parsed[jwk.Kid] = pub
	}
	return parsed
}
