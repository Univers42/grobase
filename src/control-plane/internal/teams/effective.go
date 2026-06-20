package teams

import "context"

// effective.go — the effective-permission resolver: the MAX of a user's direct
// project grant and any grant via team membership, org-bounded and TTL-aware,
// deny-by-default. The MAX is taken in Go via rank() — NEVER a lexical SQL ORDER BY,
// because owner|admin|writer|reader do not sort by privilege alphabetically.

// EffectiveRole returns the user's strongest live project role within (orgID,
// projectID): direct user grants OR team grants for teams the user belongs to in
// the org. ok=false ⇒ no live grant (deny). Expired/revoked grants are excluded in
// SQL; the org_id bound means a grant can never leak across orgs.
func (s *Service) EffectiveRole(ctx context.Context, orgID, projectID, userID string) (ProjectRole, bool) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT g.project_role
		  FROM public.project_grants g
		 WHERE g.project_id = $1::uuid
		   AND g.org_id     = $2::uuid
		   AND g.revoked_at IS NULL
		   AND (g.expires_at IS NULL OR g.expires_at > now())
		   AND (
		        (g.grantee_kind = 'user' AND g.grantee_id = $3)
		     OR (g.grantee_kind = 'team' AND g.grantee_id IN (
		            SELECT tm.team_id::text FROM public.team_members tm
		              JOIN public.teams t ON t.id = tm.team_id
		             WHERE tm.user_id = $3 AND t.org_id = $2::uuid)))`,
		projectID, orgID, userID)
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
