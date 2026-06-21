/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   teams_crud.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:32 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:34 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// teams_crud.go — team lifecycle, all org-bounded (every query filters org_id, so a
// team is invisible/untouchable outside its org by construction).

// CreateTeam inserts a team in orgID and audits team.create. A duplicate (org,slug)
// → ErrConflict.
func (s *Service) CreateTeam(ctx context.Context, orgID string, req CreateTeamRequest, actor string) (Team, error) {
	var t Team
	row := s.queryRow(ctx, `
		INSERT INTO public.teams (org_id, slug, name, metadata, created_by)
		VALUES ($1::uuid, $2, $3, $4::jsonb, NULLIF($5,''))
		RETURNING id::text, org_id::text, slug, name, metadata::text, created_by,
		          created_at::text, updated_at::text`,
		orgID, req.Slug, req.Name, marshalMeta(req.Metadata), actor)
	if err := scanTeam(row, &t); err != nil {
		if pg.IsUniqueViolation(err) {
			return Team{}, ErrConflict
		}
		return Team{}, err
	}
	s.emitAudit(ctx, orgID, actor, "team.create", t.Slug)
	return t, nil
}

// GetTeam reads one team by id within orgID (ErrNotFound when absent).
func (s *Service) GetTeam(ctx context.Context, orgID, teamID string) (Team, error) {
	var t Team
	row := s.queryRow(ctx, selectTeam+` WHERE id::text=$1 AND org_id::text=$2`, teamID, orgID)
	if err := scanTeam(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Team{}, ErrNotFound
		}
		return Team{}, err
	}
	return t, nil
}

// ListTeams returns orgID's teams, slug-ordered.
func (s *Service) ListTeams(ctx context.Context, orgID string) ([]Team, error) {
	rows, err := s.db.AdminQuery(ctx, selectTeam+` WHERE org_id::text=$1 ORDER BY slug`, orgID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Team, 0)
	for rows.Next() {
		var t Team
		if err := scanTeam(rows, &t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// UpdateTeam patches name/metadata (nil keeps the current value) and audits.
func (s *Service) UpdateTeam(ctx context.Context, orgID, teamID string, req UpdateTeamRequest, actor string) (Team, error) {
	var meta any
	if req.Metadata != nil {
		meta = marshalMeta(req.Metadata)
	}
	var t Team
	row := s.queryRow(ctx, `
		UPDATE public.teams SET name = COALESCE($3, name),
		       metadata = COALESCE($4::jsonb, metadata), updated_at = now()
		 WHERE id::text=$1 AND org_id::text=$2
		RETURNING id::text, org_id::text, slug, name, metadata::text, created_by,
		          created_at::text, updated_at::text`,
		teamID, orgID, req.Name, meta)
	if err := scanTeam(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Team{}, ErrNotFound
		}
		return Team{}, err
	}
	s.emitAudit(ctx, orgID, actor, "team.update", t.Slug)
	return t, nil
}

// DeleteTeam removes a team (cascading its members + team grants) and audits.
func (s *Service) DeleteTeam(ctx context.Context, orgID, teamID, actor string) error {
	tag, err := s.exec(ctx, `DELETE FROM public.teams WHERE id::text=$1 AND org_id::text=$2`, teamID, orgID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	s.emitAudit(ctx, orgID, actor, "team.delete", teamID)
	return nil
}
