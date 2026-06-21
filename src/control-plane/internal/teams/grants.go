/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   grants.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:05 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import "context"

// grants.go — project-role grants (User→Project and Team→Project), all org-bounded.
// A re-grant of the same (project, grantee) UPDATEs the role (idempotent, via the
// partial unique index on revoked_at IS NULL). The GitHub-sync path never overwrites
// a `manual` grant ("manual wins"), keeping vault42 the final RBAC authority.

const selectGrant = `
  SELECT id::text, project_id::text, org_id::text, grantee_kind, grantee_id,
         project_role, granted_by, granted_at::text, expires_at::text, source
    FROM public.project_grants`

// Grant upserts a manual (project, grantee)→role within orgID and audits.
func (s *Service) Grant(ctx context.Context, orgID, projectID string, req GrantRequest, actor string) (ProjectGrant, error) {
	if !validProjectRole(req.ProjectRole) {
		return ProjectGrant{}, ErrBadRole
	}
	var g ProjectGrant
	row := s.queryRow(ctx, `
		INSERT INTO public.project_grants
		  (project_id, org_id, grantee_kind, grantee_id, project_role, granted_by, expires_at, source)
		VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, NULLIF($7,'')::timestamptz, 'manual')
		ON CONFLICT (project_id, grantee_kind, grantee_id) WHERE revoked_at IS NULL
		DO UPDATE SET project_role = EXCLUDED.project_role, expires_at = EXCLUDED.expires_at,
		             granted_by = EXCLUDED.granted_by, source = 'manual', granted_at = now()
		RETURNING id::text, project_id::text, org_id::text, grantee_kind, grantee_id,
		          project_role, granted_by, granted_at::text, expires_at::text, source`,
		projectID, orgID, req.GranteeKind, req.GranteeID, string(req.ProjectRole), actor, req.ExpiresAt)
	if err := scanGrant(row, &g); err != nil {
		return ProjectGrant{}, err
	}
	s.emitAudit(ctx, orgID, actor, "project.grant", projectID+"/"+req.GranteeKind+":"+req.GranteeID)
	return g, nil
}

// Revoke marks a grant revoked (instant deny) within orgID and audits.
func (s *Service) Revoke(ctx context.Context, orgID, grantID, actor string) error {
	tag, err := s.exec(ctx, `
		UPDATE public.project_grants SET revoked_at = now()
		 WHERE id::text=$1 AND org_id::text=$2 AND revoked_at IS NULL`, grantID, orgID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	s.emitAudit(ctx, orgID, actor, "project.revoke", grantID)
	return nil
}

// ListProjectGrants returns the live grants on a project within orgID.
func (s *Service) ListProjectGrants(ctx context.Context, orgID, projectID string) ([]ProjectGrant, error) {
	rows, err := s.db.AdminQuery(ctx, selectGrant+`
		 WHERE project_id::text=$1 AND org_id::text=$2 AND revoked_at IS NULL
		 ORDER BY grantee_kind, grantee_id`, projectID, orgID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ProjectGrant, 0)
	for rows.Next() {
		var g ProjectGrant
		if err := scanGrant(rows, &g); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// SyncGrantInput is one idempotent grant from the GitHub sync (separate plan P5).
type SyncGrantInput struct {
	OrgID       string
	ProjectID   string
	GranteeKind string
	GranteeID   string
	ProjectRole ProjectRole
}

// UpsertSyncGrant idempotently upserts a github_sync grant, but NEVER overwrites a
// manual grant (the DO UPDATE is guarded by source <> 'manual').
func (s *Service) UpsertSyncGrant(ctx context.Context, in SyncGrantInput) error {
	if !validProjectRole(in.ProjectRole) {
		return ErrBadRole
	}
	return s.db.AdminExec(ctx, `
		INSERT INTO public.project_grants
		  (project_id, org_id, grantee_kind, grantee_id, project_role, granted_by, source)
		VALUES ($1::uuid, $2::uuid, $3, $4, $5, 'github_sync', 'github_sync')
		ON CONFLICT (project_id, grantee_kind, grantee_id) WHERE revoked_at IS NULL
		DO UPDATE SET project_role = EXCLUDED.project_role, granted_at = now()
		 WHERE public.project_grants.source <> 'manual'`,
		in.ProjectID, in.OrgID, in.GranteeKind, in.GranteeID, string(in.ProjectRole))
}

// scanGrant reads a project_grants row in the selectGrant column order.
func scanGrant(row rowScanner, g *ProjectGrant) error {
	var role string
	var expires *string
	if err := row.Scan(&g.ID, &g.ProjectID, &g.OrgID, &g.GranteeKind, &g.GranteeID,
		&role, &g.GrantedBy, &g.GrantedAt, &expires, &g.Source); err != nil {
		return err
	}
	g.ProjectRole = ProjectRole(role)
	g.ExpiresAt = expires
	return nil
}
