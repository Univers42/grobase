/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_tokens.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:55:33 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:55:34 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package scim

import (
	"context"
	"strings"
)

// store_tokens.go — the scim_tokens persistence (issue / verify / touch /
// revoke). Split out of store.go to keep each file at ≤5 funcs; behavior is
// byte-identical.

// IssueToken creates a SCIM bearer token for (tenantID, orgID) and returns the
// CLEARTEXT once. Only the sha256 is stored. orgID may be empty (set later), but
// provisioning ops fail with ErrNoOrg until it is bound.
func (s *store) IssueToken(ctx context.Context, tenantID, orgID, description string) (cleartext, tokenID string, err error) {
	cleartext, err = newCleartextToken()
	if err != nil {
		return "", "", err
	}
	rows, err := s.db.AdminQuery(ctx, `
		INSERT INTO public.scim_tokens (tenant_id, org_id, token_hash, description)
		VALUES ($1, NULLIF($2,''), $3, $4)
		RETURNING id::text`,
		tenantID, orgID, hashToken(cleartext), description)
	if err != nil {
		return "", "", err
	}
	defer rows.Close()
	if !rows.Next() {
		return "", "", rows.Err()
	}
	if err := rows.Scan(&tokenID); err != nil {
		return "", "", err
	}
	return cleartext, tokenID, nil
}

// VerifyToken resolves a cleartext SCIM bearer to its TokenBinding (the tenant +
// org it authorizes). A token that is unknown OR revoked (revoked_at IS NOT NULL)
// returns ErrTokenInvalid — this IS the per-tenant wall + the revocation gate.
func (s *store) VerifyToken(ctx context.Context, cleartext string) (TokenBinding, error) {
	if strings.TrimSpace(cleartext) == "" {
		return TokenBinding{}, ErrTokenInvalid
	}
	rows, err := s.db.AdminQuery(ctx, `
		SELECT id::text, tenant_id, COALESCE(org_id,'')
		  FROM public.scim_tokens
		 WHERE token_hash = $1 AND revoked_at IS NULL`,
		hashToken(cleartext))
	if err != nil {
		return TokenBinding{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		if rows.Err() != nil {
			return TokenBinding{}, rows.Err()
		}
		return TokenBinding{}, ErrTokenInvalid
	}
	var b TokenBinding
	if err := rows.Scan(&b.TokenID, &b.TenantID, &b.OrgID); err != nil {
		return TokenBinding{}, err
	}
	return b, nil
}

// Touch stamps last_used_at on a token (best-effort observability of IdP sync
// activity). A failure here never fails the SCIM request.
func (s *store) Touch(ctx context.Context, tokenID string) {
	_ = s.db.AdminExec(ctx,
		`UPDATE public.scim_tokens SET last_used_at = now() WHERE id = $1::uuid`, tokenID)
}

// Revoke marks a token revoked (idempotent). After this, VerifyToken returns
// ErrTokenInvalid for it — the load-bearing revocation gate.
func (s *store) Revoke(ctx context.Context, tenantID, tokenID string) error {
	return s.db.AdminExec(ctx,
		`UPDATE public.scim_tokens SET revoked_at = now()
		   WHERE id = $1::uuid AND tenant_id = $2 AND revoked_at IS NULL`,
		tokenID, tenantID)
}
