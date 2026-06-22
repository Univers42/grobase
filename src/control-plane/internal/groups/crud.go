/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   crud.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package groups

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// crud.go — group lifecycle. Exactly one group per project (UNIQUE(project_id)); the name is
// always derived as "<project>'s group" (also enforced by the DB CHECK).

const selectGroup = `
  SELECT id::text, project_id::text, COALESCE(org_id::text,''), name, created_by, created_at::text
    FROM public.groups`

// CreateGroup inserts the project's group (name = "<projectName>'s group"). A project that
// already has a group → ErrConflict.
func (s *Service) CreateGroup(ctx context.Context, projectID, orgID, projectName, actor string) (Group, error) {
	var g Group
	row := s.db.AdminQueryRow(ctx, `
		INSERT INTO public.groups (project_id, org_id, name, created_by)
		VALUES ($1::uuid, NULLIF($2,'')::uuid, $3, NULLIF($4,''))
		RETURNING id::text, project_id::text, COALESCE(org_id::text,''), name, created_by, created_at::text`,
		projectID, orgID, projectName+"'s group", actor)
	if err := scanGroup(row, &g); err != nil {
		if pg.IsUniqueViolation(err) {
			return Group{}, ErrConflict
		}
		return Group{}, err
	}
	return g, nil
}

// GetGroupByID reads one group by id (ErrNotFound when absent).
func (s *Service) GetGroupByID(ctx context.Context, groupID string) (Group, error) {
	var g Group
	row := s.db.AdminQueryRow(ctx, selectGroup+` WHERE id::text=$1`, groupID)
	if err := scanGroup(row, &g); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Group{}, ErrNotFound
		}
		return Group{}, err
	}
	return g, nil
}

// ListProjectGroups returns the project's group(s) — effectively the single group.
func (s *Service) ListProjectGroups(ctx context.Context, projectID string) ([]Group, error) {
	rows, err := s.db.AdminQuery(ctx, selectGroup+` WHERE project_id::text=$1 ORDER BY created_at`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Group, 0)
	for rows.Next() {
		var g Group
		if err := scanGroup(rows, &g); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}
