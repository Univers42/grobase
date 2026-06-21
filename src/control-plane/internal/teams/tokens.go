/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   tokens.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:38 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:39 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import (
	"context"
	"time"
)

// tokens.go — short-lived, revocable, NON-ESCALATING scoped tokens. The minted role
// can never exceed the issuer's effective role for the scope (token_bound.go). Only
// the sha256 hash is stored; the cleartext is returned exactly once.

// ErrBadScope — an unknown scope_kind on a token request (400).
const ErrBadScope teamsErr = "scope_kind must be one of org|project"

// CreateToken mints a scoped token bound to the issuer's effective role and audits.
// A role above the issuer's → ErrEscalation; no standing in scope → ErrForbidden.
func (s *Service) CreateToken(ctx context.Context, orgID string, req TokenCreateRequest, issuer string) (TokenCreateResponse, error) {
	if !validProjectRole(req.ProjectRole) {
		return TokenCreateResponse{}, ErrBadRole
	}
	if req.ScopeKind != "org" && req.ScopeKind != "project" {
		return TokenCreateResponse{}, ErrBadScope
	}
	caller, ok := s.resolveCallerRole(ctx, orgID, req, issuer)
	if !ok {
		return TokenCreateResponse{}, ErrForbidden
	}
	if !roleWithinCaller(req.ProjectRole, caller) {
		return TokenCreateResponse{}, ErrEscalation
	}
	return s.mintToken(ctx, orgID, req, issuer)
}

// mintToken generates + persists the token row, returning the cleartext once.
func (s *Service) mintToken(ctx context.Context, orgID string, req TokenCreateRequest, issuer string) (TokenCreateResponse, error) {
	ttl := req.TTLSeconds
	if ttl <= 0 {
		ttl = 3600
	}
	scopeID := req.ScopeID
	if req.ScopeKind == "org" && scopeID == "" {
		scopeID = orgID
	}
	cleartext, prefix, hash, err := generateToken()
	if err != nil {
		return TokenCreateResponse{}, err
	}
	expires := s.now().UTC().Add(time.Duration(ttl) * time.Second)
	var t RBACToken
	row := s.queryRow(ctx, `
		INSERT INTO public.rbac_tokens
		  (token_hash, token_prefix, issuer_user_id, scope_kind, scope_id, org_id, project_role, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6::uuid, $7, $8)
		RETURNING id::text, token_prefix, issuer_user_id, scope_kind, scope_id, org_id::text,
		          project_role, created_at::text, expires_at::text`,
		hash, prefix, issuer, req.ScopeKind, scopeID, orgID, string(req.ProjectRole), expires)
	if err := scanToken(row, &t); err != nil {
		return TokenCreateResponse{}, err
	}
	s.emitAudit(ctx, orgID, issuer, "token.create", t.ScopeKind+":"+scopeID)
	return TokenCreateResponse{RBACToken: t, Token: cleartext}, nil
}

// ListTokens returns the live (un-revoked) tokens issued under orgID, redacted.
func (s *Service) ListTokens(ctx context.Context, orgID string) ([]RBACToken, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT id::text, token_prefix, issuer_user_id, scope_kind, scope_id, org_id::text,
		       project_role, created_at::text, expires_at::text
		  FROM public.rbac_tokens WHERE org_id::text=$1 AND revoked_at IS NULL
		 ORDER BY created_at DESC`, orgID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]RBACToken, 0)
	for rows.Next() {
		var t RBACToken
		if err := scanToken(rows, &t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// RevokeToken marks a token revoked (instant) within orgID and audits.
func (s *Service) RevokeToken(ctx context.Context, orgID, tokenID, actor string) error {
	tag, err := s.exec(ctx, `
		UPDATE public.rbac_tokens SET revoked_at = now()
		 WHERE id::text=$1 AND org_id::text=$2 AND revoked_at IS NULL`, tokenID, orgID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	s.emitAudit(ctx, orgID, actor, "token.revoke", tokenID)
	return nil
}

// scanToken reads a redacted rbac_tokens row.
func scanToken(row rowScanner, t *RBACToken) error {
	var role string
	if err := row.Scan(&t.ID, &t.TokenPrefix, &t.IssuerUserID, &t.ScopeKind, &t.ScopeID,
		&t.OrgID, &role, &t.CreatedAt, &t.ExpiresAt); err != nil {
		return err
	}
	t.ProjectRole = ProjectRole(role)
	return nil
}
