/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   account_apps.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import "context"

// StampAccount records, additively, which account a self-serve app-tenant belongs to —
// metadata.account_user_id. It is NOT owner_user_id (that column stays NULL for app-tenants so
// findForUser's 1:1 account→primary-tenant mapping is untouched); the metadata tag is purely the
// listing key for ListByAccount.
func (s *Service) StampAccount(ctx context.Context, slug, accountUserID string) error {
	tag, err := s.exec(ctx,
		`UPDATE public.tenants
		    SET metadata = COALESCE(metadata,'{}'::jsonb) || jsonb_build_object('account_user_id', $2::text)
		  WHERE slug=$1`, slug, accountUserID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListByAccount returns the active app-tenants created by one account (newest first).
func (s *Service) ListByAccount(ctx context.Context, accountUserID string) ([]Tenant, error) {
	rows, err := s.db.AdminQuery(ctx, selectTenant+`
		 WHERE metadata->>'account_user_id' = $1 AND status <> 'deleted'
		 ORDER BY created_at DESC`, accountUserID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Tenant, 0)
	for rows.Next() {
		var t Tenant
		if err := scanTenant(rows, &t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
