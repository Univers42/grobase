/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   state.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:56:49 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:56:50 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package sso

import (
	"crypto/rand"
	"encoding/base64"
	"sync"
	"time"
)

// stateTTL bounds how long a BeginLogin -> FinishLogin round-trip may take. The
// OIDC `state` is single-use (CSRF defense) and short-lived; a stale state MUST
// NOT be completable, so FinishLogin rejects (401) any state aged past this.
// Replaying an old state therefore fails on TTL, and a matching-but-expired state
// is one of the gate's REJECT vectors. (Mirrors passkeys.challengeTTL.)
const stateTTL = 5 * time.Minute

// loginState holds the server-side state between BeginLogin and FinishLogin. The
// nonce is bound INTO the IdP authorize request and MUST come back inside the
// id_token (replay defense); connID pins which connection's keys verify the
// id_token; createdAt drives the TTL. None of this is trusted from the client —
// it is keyed server-side by the opaque `state` value handed to the IdP.
type loginState struct {
	connID    string
	nonce     string
	expiresAt time.Time
}

// stateStore is a small in-memory, TTL-bounded, single-use state store — the
// exact pattern passkeys.sessionStore uses (one control-plane replica owns the
// states it issued; a horizontal deployment backs it with Redis). Entries are
// removed on take (single-use) and swept on TTL.
type stateStore struct {
	mu  sync.Mutex
	m   map[string]loginState
	now func() time.Time
}

func newStateStore() *stateStore {
	return &stateStore{m: make(map[string]loginState), now: time.Now}
}

// put stores a login state under a fresh random `state` token and returns it. It
// opportunistically sweeps expired entries so abandoned logins cannot accumulate.
func (s *stateStore) put(ls loginState) (string, error) {
	id, err := randomToken()
	if err != nil {
		return "", err
	}
	ls.expiresAt = s.now().Add(stateTTL)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweepLocked()
	s.m[id] = ls
	return id, nil
}

// take atomically fetches AND removes a state (single-use). A missing or expired
// id returns ok=false — so a replayed/expired state cannot finish. The delete
// happens BEFORE the TTL check (take()-deletes-then-checks-TTL) so even a same-id
// retry races to a miss. (Mirrors passkeys.sessionStore.take.)
func (s *stateStore) take(id string) (loginState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ls, ok := s.m[id]
	if !ok {
		return loginState{}, false
	}
	delete(s.m, id)
	if s.now().After(ls.expiresAt) {
		return loginState{}, false
	}
	return ls, true
}

func (s *stateStore) sweepLocked() {
	now := s.now()
	for k, v := range s.m {
		if now.After(v.expiresAt) {
			delete(s.m, k)
		}
	}
}

// randomToken returns a 32-byte URL-safe random token used for both `state` and
// `nonce` (high-entropy, single-use; the same primitive as passkeys.randomID).
func randomToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
