/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_selfserve.go                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:19 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:21 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"context"
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// VerifyKey resolves a raw tenant API key to its tenant slug, delegating to the
// single-source tenants.Service verifier (the returned VerifyKeyResponse exposes
// .Valid and .TenantID, which is the tenant slug). Used only by the self-serve
// read route. Mirrors the MODULE-SLICE CONTRACT in handler.go.
func (s *Service) VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error) {
	if s.keys == nil {
		return tenants.VerifyKeyResponse{}, fmt.Errorf("backup: self-serve key verification not wired")
	}
	return s.keys.VerifyKey(ctx, raw)
}

// TenantForUser resolves a GoTrue user id to the slug of the tenant it owns,
// returning ErrNotFound when the user owns no tenant yet. tenant_id is keyed by
// owner_user_id (mirrors tenants.findForUser; userID is a bind param). Used only
// by the self-serve read route.
func (s *Service) TenantForUser(ctx context.Context, userID string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT slug FROM public.tenants WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", rerr
		}
		return "", ErrNotFound
	}
	var slug string
	if err := rows.Scan(&slug); err != nil {
		return "", err
	}
	return slug, nil
}
