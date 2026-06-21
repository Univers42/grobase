/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   members.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:19 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:21 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package teams

import "context"

// members.go — team membership, org-bounded via a GetTeam existence check (so a
// member can only ever be added to a team that lives in the caller's org).

// AddTeamMember upserts (team, user)→team_role within orgID and audits. team_role
// defaults to "member"; "manager" lets that user invite further members.
func (s *Service) AddTeamMember(ctx context.Context, orgID, teamID string, req AddTeamMemberRequest, actor string) error {
	team, err := s.GetTeam(ctx, orgID, teamID)
	if err != nil {
		return err
	}
	role := req.TeamRole
	if role != "manager" {
		role = "member"
	}
	if err := s.db.AdminExec(ctx, `
		INSERT INTO public.team_members (team_id, user_id, team_role, added_by)
		VALUES ($1::uuid, $2, $3, NULLIF($4,''))
		ON CONFLICT (team_id, user_id) DO UPDATE SET team_role = EXCLUDED.team_role`,
		teamID, req.UserID, role, actor); err != nil {
		return err
	}
	s.emitAudit(ctx, orgID, actor, "team.member.add", team.Slug+"/"+req.UserID)
	return nil
}

// RemoveTeamMember deletes a (team, user) membership within orgID and audits.
func (s *Service) RemoveTeamMember(ctx context.Context, orgID, teamID, userID, actor string) error {
	team, err := s.GetTeam(ctx, orgID, teamID)
	if err != nil {
		return err
	}
	tag, err := s.exec(ctx,
		`DELETE FROM public.team_members WHERE team_id::text=$1 AND user_id=$2`, teamID, userID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	s.emitAudit(ctx, orgID, actor, "team.member.remove", team.Slug+"/"+userID)
	return nil
}

// ListTeamMembers returns a team's membership within orgID, join-order.
func (s *Service) ListTeamMembers(ctx context.Context, orgID, teamID string) ([]TeamMember, error) {
	if _, err := s.GetTeam(ctx, orgID, teamID); err != nil {
		return nil, err
	}
	rows, err := s.db.AdminQuery(ctx, `
		SELECT team_id::text, user_id, team_role, created_at::text
		  FROM public.team_members WHERE team_id::text=$1 ORDER BY created_at`, teamID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]TeamMember, 0)
	for rows.Next() {
		var m TeamMember
		if err := rows.Scan(&m.TeamID, &m.UserID, &m.TeamRole, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// isTeamManager reports whether userID is a manager of teamID (the team-level grant
// that lets a non-org-admin invite team members).
func (s *Service) isTeamManager(ctx context.Context, teamID, userID string) bool {
	var role string
	row := s.queryRow(ctx,
		`SELECT team_role FROM public.team_members WHERE team_id::text=$1 AND user_id=$2`, teamID, userID)
	if err := row.Scan(&role); err != nil {
		return false
	}
	return role == "manager"
}
