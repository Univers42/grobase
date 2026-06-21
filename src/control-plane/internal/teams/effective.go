/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   effective.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:03 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:04 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import "context"

// effective.go — the effective-permission resolver: the MAX of a user's direct project
// grant and any grant via team OR group membership, org-bounded and TTL-aware,
// deny-by-default. The MAX is taken in Go via rank() — NEVER a lexical SQL ORDER BY,
// because owner|admin|writer|reader do not sort by privilege alphabetically.

// granteeMatch is the grantee-resolution clause shared by both resolvers: a direct user
// grant ($3=userID), a grant via a team the user belongs to in the org ($2=orgID), or a
// grant via the project's group ($1=projectID). A group is project-scoped, so it joins on
// project_id (not org_id) — which makes it work for standalone projects too.
const granteeMatch = `
	        (g.grantee_kind = 'user'  AND g.grantee_id = $3)
	     OR (g.grantee_kind = 'team'  AND g.grantee_id IN (
	            SELECT tm.team_id::text FROM public.team_members tm
	              JOIN public.teams t ON t.id = tm.team_id
	             WHERE tm.user_id = $3 AND t.org_id = $2::uuid))
	     OR (g.grantee_kind = 'group' AND g.grantee_id IN (
	            SELECT gm.group_id::text FROM public.group_members gm
	              JOIN public.groups gr ON gr.id = gm.group_id
	             WHERE gm.user_id = $3 AND gr.project_id = $1::uuid))`

// EffectiveRole returns the user's strongest live PROJECT-WIDE role within (orgID,
// projectID): the MAX over direct user grants, team grants, and group grants across ALL
// environments. ok=false ⇒ no live grant (deny). The org_id bound stops cross-org leakage.
func (s *Service) EffectiveRole(ctx context.Context, orgID, projectID, userID string) (ProjectRole, bool) {
	return s.maxRole(ctx, `
		SELECT g.project_role FROM public.project_grants g
		 WHERE g.project_id = $1::uuid AND g.org_id = $2::uuid
		   AND g.revoked_at IS NULL AND (g.expires_at IS NULL OR g.expires_at > now())
		   AND (`+granteeMatch+`)`, projectID, orgID, userID)
}

// EffectiveRoleInEnv returns the user's strongest live role for ONE environment: grants
// scoped to that env PLUS project-wide grants (env_id IS NULL). envID "" ⇒ project-wide only.
func (s *Service) EffectiveRoleInEnv(ctx context.Context, orgID, projectID, userID, envID string) (ProjectRole, bool) {
	return s.maxRole(ctx, `
		SELECT g.project_role FROM public.project_grants g
		 WHERE g.project_id = $1::uuid AND g.org_id = $2::uuid
		   AND g.revoked_at IS NULL AND (g.expires_at IS NULL OR g.expires_at > now())
		   AND (g.env_id IS NULL OR g.env_id = NULLIF($4,'')::uuid)
		   AND (`+granteeMatch+`)`, projectID, orgID, userID, envID)
}

// maxRole runs a project_grants role query and returns the MAX by rank() (deny if empty).
func (s *Service) maxRole(ctx context.Context, sql string, args ...any) (ProjectRole, bool) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return "", false
	}
	defer rows.Close()
	best := -1
	var bestRole ProjectRole
	for rows.Next() {
		var role string
		if err := rows.Scan(&role); err != nil {
			return "", false
		}
		if r := rank(ProjectRole(role)); r > best {
			best, bestRole = r, ProjectRole(role)
		}
	}
	if best < 0 {
		return "", false
	}
	return bestRole, true
}
