/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   scope.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package invites

import "context"

// scope.go — scope→org resolvers for the auth gate and the accept join. A group carries a
// denormalized org_id; a project(=tenant) carries org_id (NULL ⇒ standalone). exists=false
// when the scope row is absent (the handler maps it to 404).

// groupOrg resolves a group's org id (""=standalone) and whether the group exists.
func (s *Service) groupOrg(ctx context.Context, groupID string) (orgID string, exists bool) {
	row := s.db.AdminQueryRow(ctx,
		`SELECT COALESCE(org_id::text,'') FROM public.groups WHERE id::text=$1`, groupID)
	if err := row.Scan(&orgID); err != nil {
		return "", false
	}
	return orgID, true
}

// projectOrg resolves a project's org id (""=standalone) and whether the project exists.
func (s *Service) projectOrg(ctx context.Context, projectID string) (orgID string, exists bool) {
	row := s.db.AdminQueryRow(ctx,
		`SELECT COALESCE(org_id::text,'') FROM public.tenants WHERE id::text=$1`, projectID)
	if err := row.Scan(&orgID); err != nil {
		return "", false
	}
	return orgID, true
}

// teamInOrg reports whether teamID belongs to orgID (so an org admin cannot invite to a team
// living outside their org).
func (s *Service) teamInOrg(ctx context.Context, orgID, teamID string) bool {
	var x string
	row := s.db.AdminQueryRow(ctx,
		`SELECT '1' FROM public.teams WHERE id::text=$1 AND org_id::text=$2`, teamID, orgID)
	return row.Scan(&x) == nil
}

// projectOwner resolves a project's owner_user_id (""=none) and whether the project exists —
// the ownership check for a standalone (org-less) project's direct invites.
func (s *Service) projectOwner(ctx context.Context, projectID string) (owner string, exists bool) {
	row := s.db.AdminQueryRow(ctx,
		`SELECT COALESCE(owner_user_id,'') FROM public.tenants WHERE id::text=$1`, projectID)
	if err := row.Scan(&owner); err != nil {
		return "", false
	}
	return owner, true
}
