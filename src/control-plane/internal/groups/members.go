/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   members.go                                         :+:      :+:    :+:   */
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

	"github.com/jackc/pgx/v5"
)

// members.go — group membership. A group is project-scoped, so a member added here is granted
// (via a group→project grant in teams.project_grants) access to that one project.

// AddGroupMember upserts (group, user) membership (idempotent).
func (s *Service) AddGroupMember(ctx context.Context, groupID, userID, actor string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.group_members (group_id, user_id, added_by)
		VALUES ($1::uuid, $2, NULLIF($3,''))
		ON CONFLICT (group_id, user_id) DO NOTHING`, groupID, userID, actor)
}

// RemoveGroupMember deletes a (group, user) membership (ErrNotFound when absent).
func (s *Service) RemoveGroupMember(ctx context.Context, groupID, userID string) error {
	var uid string
	row := s.db.AdminQueryRow(ctx,
		`DELETE FROM public.group_members WHERE group_id::text=$1 AND user_id=$2 RETURNING user_id`,
		groupID, userID)
	if err := row.Scan(&uid); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	return nil
}

// ListGroupMembers returns a group's membership, join-order.
func (s *Service) ListGroupMembers(ctx context.Context, groupID string) ([]GroupMember, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT group_id::text, user_id, created_at::text
		  FROM public.group_members WHERE group_id::text=$1 ORDER BY created_at`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]GroupMember, 0)
	for rows.Next() {
		var m GroupMember
		if err := rows.Scan(&m.GroupID, &m.UserID, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
