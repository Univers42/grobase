/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_users_mutations.go                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:55:35 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:55:37 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package scim

import (
	"context"
	"encoding/json"
)

// store_users_mutations.go — the scim_users update/set-active/delete queries.
// Split out of store.go to keep each file at ≤5 funcs; behavior is
// byte-identical.

// UpdateUser replaces the mutable fields of a SCIM user (PUT / PATCH). Keyed by
// (tenantID, scimID) — the wall.
func (s *store) UpdateUser(ctx context.Context, u userRecord) error {
	emailJSON, _ := json.Marshal(u.Emails)
	return s.db.AdminExec(ctx, `
		UPDATE public.scim_users
		   SET user_name = $3, display_name = $4, emails = $5::jsonb,
		       active = $6, updated_at = now()
		 WHERE tenant_id = $1 AND scim_id = $2`,
		u.TenantID, u.SCIMID, u.UserName, u.DisplayName, string(emailJSON), u.Active)
}

// SetActive flips the SCIM user's active flag (deactivate / reactivate). Keyed by
// the wall. It also mirrors the flag onto org_members.active (the soft-disable),
// scoped by org_id+user_id so it never touches another org's membership.
func (s *store) SetActive(ctx context.Context, u userRecord, active bool) error {
	if err := s.db.AdminExec(ctx, `
		UPDATE public.scim_users SET active = $3, updated_at = now()
		 WHERE tenant_id = $1 AND scim_id = $2`,
		u.TenantID, u.SCIMID, active); err != nil {
		return err
	}
	if u.OrgID == "" {
		return nil
	}
	return s.db.AdminExec(ctx, `
		UPDATE public.org_members SET active = $3
		 WHERE org_id::text = $1 AND user_id = $2`,
		u.OrgID, u.UserID, active)
}

// DeleteUser removes the SCIM mapping row (the org membership removal is done by
// the service via orgs.Service.RemoveMember). Keyed by the wall.
func (s *store) DeleteUser(ctx context.Context, tenantID, scimID string) error {
	return s.db.AdminExec(ctx,
		`DELETE FROM public.scim_users WHERE tenant_id = $1 AND scim_id = $2`,
		tenantID, scimID)
}
