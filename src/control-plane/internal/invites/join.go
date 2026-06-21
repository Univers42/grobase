/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   join.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:35:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:35:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package invites

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// join.go — the scope-dispatch that materializes membership/grant for an accepted invite.

// joinScope routes the accepted invite to the right membership/grant insert.
func joinScope(ctx context.Context, tx pgx.Tx, inv Invite, acceptedBy string) error {
	switch inv.ScopeKind {
	case "team":
		return joinTeam(ctx, tx, inv, acceptedBy)
	case "group":
		return joinGroup(ctx, tx, inv.ScopeID, acceptedBy)
	case "project":
		return joinProject(ctx, tx, inv, acceptedBy)
	default:
		return ErrBadScope
	}
}

// joinTeam adds the user to the team — and, since a team member is always an org member,
// upserts the org membership first (default developer; existing role kept).
func joinTeam(ctx context.Context, tx pgx.Tx, inv Invite, acceptedBy string) error {
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.org_members (org_id, user_id, role, invited_by)
		VALUES (NULLIF($1,'')::uuid, $2, 'developer', NULL)
		ON CONFLICT (org_id, user_id) DO NOTHING`, inv.OrgID, acceptedBy); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO public.team_members (team_id, user_id, team_role, added_by)
		VALUES ($1::uuid, $2, $3, NULL)
		ON CONFLICT (team_id, user_id) DO UPDATE SET team_role = EXCLUDED.team_role`,
		inv.ScopeID, acceptedBy, inv.Role)
	return err
}

// joinGroup adds the user to the project-scoped group.
func joinGroup(ctx context.Context, tx pgx.Tx, groupID, acceptedBy string) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO public.group_members (group_id, user_id, added_by)
		VALUES ($1::uuid, $2, NULL) ON CONFLICT (group_id, user_id) DO NOTHING`,
		groupID, acceptedBy)
	return err
}

// joinProject upserts a direct user→project grant (source=invite) for the invited role.
func joinProject(ctx context.Context, tx pgx.Tx, inv Invite, acceptedBy string) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO public.project_grants
		  (project_id, org_id, grantee_kind, grantee_id, project_role, granted_by, source)
		VALUES ($1::uuid, NULLIF($2,'')::uuid, 'user', $3, $4, $3, 'invite')
		ON CONFLICT (project_id, grantee_kind, grantee_id,
		             COALESCE(env_id, '00000000-0000-0000-0000-000000000000'::uuid)) WHERE revoked_at IS NULL
		DO UPDATE SET project_role = EXCLUDED.project_role, source = 'invite', granted_at = now()`,
		inv.ScopeID, inv.OrgID, acceptedBy, inv.Role)
	return err
}
