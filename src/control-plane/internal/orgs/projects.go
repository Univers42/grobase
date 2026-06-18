package orgs

import "context"

// projects.go — the last-owner count input + the project <-> org linkage (the one
// additive control-plane write the provision path makes).

// ownerCount reports whether userID is an owner of the org and how many owners
// the org has in total — the inputs to the last-owner guard.
func (s *Service) ownerCount(ctx context.Context, orgID, userID string) (isOwner bool, owners int, err error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT
		  COALESCE(bool_or(user_id=$2 AND role='owner'), false) AS is_owner,
		  COUNT(*) FILTER (WHERE role='owner')                  AS owners
		FROM public.org_members WHERE org_id::text=$1`, orgID, userID)
	if err != nil {
		return false, 0, err
	}
	defer rows.Close()
	if !rows.Next() {
		return false, 0, rows.Err()
	}
	if err := rows.Scan(&isOwner, &owners); err != nil {
		return false, 0, err
	}
	return isOwner, owners, nil
}

// AttachProjectToOrg stamps tenants.org_id = orgID for the project slug. This is
// the ONLY org write the provision path makes — additive, AFTER the reconciler
// has run. It is read by NO request-path code (the data plane never selects it).
func (s *Service) AttachProjectToOrg(ctx context.Context, projectSlug, orgID string) error {
	return s.db.AdminExec(ctx,
		`UPDATE public.tenants SET org_id = $2::uuid WHERE slug = $1`, projectSlug, orgID)
}

// ListProjects returns the project slugs (+ name/plan/status) attached to an org.
func (s *Service) ListProjects(ctx context.Context, orgID string) ([]map[string]any, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT slug, name, plan, status FROM public.tenants
		 WHERE org_id::text=$1 AND status <> 'deleted' ORDER BY created_at DESC LIMIT 500`, orgID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]map[string]any, 0)
	for rows.Next() {
		var slug, name, plan, status string
		if err := rows.Scan(&slug, &name, &plan, &status); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"id": slug, "name": name, "plan": plan, "status": status})
	}
	return out, rows.Err()
}
