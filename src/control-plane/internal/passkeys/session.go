/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   session.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:30 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package passkeys

import (
	"crypto/rand"
	"encoding/base64"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"
)

// challengeTTL bounds how long a begin→finish ceremony may take. WebAuthn
// challenges are single-use and short-lived; a stale challenge MUST NOT be
// completable, so the finish path rejects (404 not-found) any challenge id that
// has aged past this. Replaying an old challenge therefore fails on TTL, and a
// matching-but-expired challenge is one of the gate's REJECT vectors.
const challengeTTL = 2 * time.Minute

// pending holds the server-side ceremony state between begin and finish. The
// go-webauthn SessionData carries the challenge + (for login) the allowed
// credential ids; it has UNEXPORTED fields, so it MUST be retained verbatim
// (never reconstructed) — which is exactly why we keep it server-side keyed by a
// one-time challengeID handed to the client, rather than trusting the client to
// echo it back.
type pending struct {
	session   *webauthn.SessionData
	tenantID  string
	userID    string
	userName  string
	display   string
	expiresAt time.Time
}

// sessionStore is a small in-memory, TTL-bounded, single-use challenge store.
// One control-plane replica owns the ceremonies it issued; a horizontal
// deployment would back this with Redis (the same snapshot pattern B2/B7 use),
// but the in-memory store keeps the MVP dependency-free and is correct for a
// single replica. Entries are removed on finish (single-use) and swept on TTL.
type sessionStore struct {
	mu  sync.Mutex
	m   map[string]pending
	now func() time.Time
}

func newSessionStore() *sessionStore {
	return &sessionStore{m: make(map[string]pending), now: time.Now}
}

// put stores a ceremony under a fresh random challengeID and returns that id.
// It opportunistically sweeps expired entries so an abandoned ceremony cannot
// accumulate (no background goroutine needed for the MVP).
func (s *sessionStore) put(p pending) (string, error) {
	id, err := randomID()
	if err != nil {
		return "", err
	}
	p.expiresAt = s.now().Add(challengeTTL)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweepLocked()
	s.m[id] = p
	return id, nil
}

// take atomically fetches AND removes a ceremony (single-use). A missing or
// expired id returns ok=false — so a replayed/expired challenge cannot finish.
func (s *sessionStore) take(id string) (pending, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.m[id]
	if !ok {
		return pending{}, false
	}
	delete(s.m, id)
	if s.now().After(p.expiresAt) {
		return pending{}, false
	}
	return p, true
}

func (s *sessionStore) sweepLocked() {
	now := s.now()
	for k, v := range s.m {
		if now.After(v.expiresAt) {
			delete(s.m, k)
		}
	}
}

// randomID returns a 32-byte URL-safe random token used as the one-time
// challenge id the client echoes back on finish.
func randomID() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
