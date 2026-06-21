/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   login.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:17 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package passkeys

import (
	"context"
	"errors"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

// BeginLogin starts an authentication ceremony for a known user. It loads the
// user's credentials (so the assertion options carry allowCredentials) and
// retains the SessionData under a one-time challengeID. A user with no passkey
// yields ErrNoCredentials (404) — there is nothing to authenticate with.
func (s *Service) BeginLogin(ctx context.Context, in BeginLoginInput) (*protocol.CredentialAssertion, string, error) {
	stored, err := s.store.LoadByUser(ctx, in.TenantID, in.UserID)
	if err != nil {
		return nil, "", err
	}
	user, err := newUser(in.UserID, in.UserID, in.UserID, stored)
	if err != nil {
		return nil, "", err
	}
	assertion, session, err := s.wa.BeginLogin(user)
	if err != nil {
		return nil, "", err
	}
	id, err := s.sessions.put(pending{
		session:  session,
		tenantID: in.TenantID,
		userID:   in.UserID,
	})
	if err != nil {
		return nil, "", err
	}
	return assertion, id, nil
}

// FinishLogin verifies the assertion signature against the stored public key,
// bumps the sign_count, and mints a session JWT. The go-webauthn ValidateLogin
// enforces, against the SERVER-HELD session: the challenge matches, the origin
// matches RPOrigins, the credential id is one this user owns, the signature
// verifies under the stored COSE key, and the sign-count moved forward (clone
// detection). ANY failure → ErrAssertionRejected (401). This is the load-bearing
// reject surface: a wrong-key signature, a replayed/!matching challenge, and a
// cross-user credential all fail here.
func (s *Service) FinishLogin(ctx context.Context, challengeID string, body []byte) (MintedSession, error) {
	p, ok := s.sessions.take(challengeID)
	if !ok {
		return MintedSession{}, ErrChallengeNotFound
	}
	stored, err := s.store.LoadByUser(ctx, p.tenantID, p.userID)
	if err != nil {
		return MintedSession{}, err
	}
	cred, err := s.validateLogin(p, stored, body)
	if err != nil {
		return MintedSession{}, err
	}
	s.bumpSignCount(ctx, p.tenantID, cred)
	return s.minter.Mint(p.userID, resolveEmail(stored, p.userID))
}

// validateLogin parses the assertion and verifies it against the server-held
// session. Every cryptographic / ownership / challenge failure is mapped to a
// single ErrAssertionRejected (401) so the caller cannot distinguish "wrong
// key" from "wrong credential" from "stale challenge" (no oracle).
func (s *Service) validateLogin(p pending, stored []storedCredential, body []byte) (*webauthn.Credential, error) {
	user, err := newUser(p.userID, p.userID, p.userID, stored)
	if err != nil {
		return nil, err
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(body)
	if err != nil {
		return nil, errors.Join(ErrAssertionRejected, wrapProtocol(err))
	}
	cred, err := s.wa.ValidateLogin(user, *p.session, parsed)
	if err != nil {
		return nil, errors.Join(ErrAssertionRejected, err)
	}
	return cred, nil
}

// bumpSignCount persists the advanced authenticator counter (replay/clone
// evidence). Best-effort: a counter-bump failure must not fail an otherwise
// valid login, but we log it (a stuck counter weakens replay detection).
func (s *Service) bumpSignCount(ctx context.Context, tenantID string, cred *webauthn.Credential) {
	credIDB64 := base64urlEncode(cred.ID)
	if err := s.store.BumpSignCount(ctx, tenantID, credIDB64, cred.Authenticator.SignCount); err != nil {
		s.log.Warn("passkeys: sign_count bump failed", "err", err, "credential_id", credIDB64)
	}
}
