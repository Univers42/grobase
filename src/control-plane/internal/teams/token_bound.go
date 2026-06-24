/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   token_bound.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:35 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:36 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"

	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// token_bound.go — the non-escalation guard + token generation. A scoped token can
// never carry a role stronger than the issuer's own effective role for that scope
// (the role analogue of tenants.scopesWithinCaller).

// roleWithinCaller reports whether requested ≤ caller by privilege rank (and both
// are valid roles).
func roleWithinCaller(requested, caller ProjectRole) bool {
	rq, cl := rank(requested), rank(caller)
	return rq >= 0 && cl >= 0 && rq <= cl
}

// resolveCallerRole resolves the issuer's effective role for the token's scope:
// a project scope → the effective project role; an org scope → the issuer's org role
// mapped onto the project lattice. ok=false ⇒ the issuer has no standing in scope.
func (s *Service) resolveCallerRole(ctx context.Context, orgID string, req TokenCreateRequest, issuer string) (ProjectRole, bool) {
	if req.ScopeKind == "project" {
		return s.EffectiveRole(ctx, orgID, req.ScopeID, issuer)
	}
	role, ok := s.orgs.MemberRole(ctx, orgID, issuer)
	if !ok {
		return "", false
	}
	return mapOrgRole(role), true
}

// mapOrgRole projects an org role onto the project-role lattice for org-scoped
// tokens (developer→writer; billing/viewer→reader).
func mapOrgRole(r orgs.Role) ProjectRole {
	switch r {
	case orgs.RoleOwner:
		return RoleOwner
	case orgs.RoleAdmin:
		return RoleAdmin
	case orgs.RoleDeveloper:
		return RoleWriter
	default:
		return RoleReader
	}
}

// generateToken mints a fresh `rbt_`-prefixed cleartext token and returns it with
// its lookup prefix and sha256 hex hash (only the hash is stored; the cleartext is
// returned to the caller exactly once).
func generateToken() (cleartext, prefix, hash string, err error) {
	var raw [32]byte
	if _, err = rand.Read(raw[:]); err != nil {
		return "", "", "", err
	}
	body := base64.RawURLEncoding.EncodeToString(raw[:])
	cleartext = "rbt_" + body
	prefix = cleartext[:12]
	sum := sha256.Sum256([]byte(cleartext))
	return cleartext, prefix, hex.EncodeToString(sum[:]), nil
}
