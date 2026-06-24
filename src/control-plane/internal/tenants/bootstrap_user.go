/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bootstrap_user.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:58:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:58:17 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// findForUser resolves the tenant owned by userID WITHOUT creating one. It
// returns ErrNotFound when the user owns no tenant yet — tenant creation is the
// explicit job of POST /v1/tenants/me/bootstrap, never a side effect of a /me
// read. (Self-serve reads use this; the bootstrap path keeps findOrCreateForUser.)
func (s *Service) findForUser(ctx context.Context, userID string) (Tenant, error) {
	row, err := s.queryOne(ctx, selectTenant+` WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return Tenant{}, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Tenant{}, ErrNotFound
		}
		return Tenant{}, err
	}
	return t, nil
}

// findOrCreateForUser resolves the tenant owned by userID, creating one when no
// row exists. A missing row means the post-signup trigger failed or a backfill
// missed this user, so it defensively creates the tenant now.
func (s *Service) findOrCreateForUser(ctx context.Context, userID, email string) (Tenant, bool, error) {
	row, err := s.queryOne(ctx, selectTenant+` WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return Tenant{}, false, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err == nil {
		return t, false, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return Tenant{}, false, err
	}
	return s.createForUser(ctx, userID, email)
}

// createForUser creates a tenant for an owner the trigger missed, recovering a
// concurrent insert (the trigger or another caller) by re-fetching on conflict.
func (s *Service) createForUser(ctx context.Context, userID, email string) (Tenant, bool, error) {
	slug := slugFromUserUUID(userID)
	name := email
	if name == "" {
		name = slug
	}
	created, err := s.Create(ctx, CreateTenantRequest{ID: slug, Name: name, OwnerUserID: userID})
	if errors.Is(err, ErrConflict) {
		t, ferr := s.findBySlug(ctx, slug)
		return t, false, ferr
	}
	if err != nil {
		return Tenant{}, false, err
	}
	return created, true, nil
}

// findBySlug fetches a tenant strictly by slug (the conflict-race re-fetch path).
func (s *Service) findBySlug(ctx context.Context, slug string) (Tenant, error) {
	row, err := s.queryOne(ctx, selectTenant+` WHERE slug = $1`, slug)
	if err != nil {
		return Tenant{}, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err != nil {
		return Tenant{}, err
	}
	return t, nil
}

// slugFromUserUUID mirrors the SQL trigger so Go and PG generate the same slug.
func slugFromUserUUID(userUUID string) string {
	out := make([]rune, 0, 2+len(userUUID))
	out = append(out, 't', '-')
	for _, r := range userUUID {
		if r == '-' {
			continue
		}
		out = append(out, r)
	}
	return string(out)
}
