/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
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
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// rowScanner is the minimal single-row read surface (satisfied by pgx.Row and pgx.Rows).
type rowScanner interface{ Scan(dest ...any) error }

// Service owns group CRUD + membership over the admin (BYPASSRLS) pool; the Go capability
// gate is the first wall, the RLS policies the second. Dependencies are injected (no globals).
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool and a logger.
func NewService(db *pg.Postgres, log *slog.Logger) *Service { return &Service{db: db, log: log} }

// projectMeta resolves a project's org id (""=standalone), its name (to derive the group
// name), and whether it exists.
func (s *Service) projectMeta(ctx context.Context, projectID string) (orgID, name string, exists bool) {
	row := s.db.AdminQueryRow(ctx,
		`SELECT COALESCE(org_id::text,''), name FROM public.tenants WHERE id::text=$1`, projectID)
	if err := row.Scan(&orgID, &name); err != nil {
		return "", "", false
	}
	return orgID, name, true
}

// groupMeta resolves a group's project + org (""=standalone) and whether it exists.
func (s *Service) groupMeta(ctx context.Context, groupID string) (projectID, orgID string, exists bool) {
	row := s.db.AdminQueryRow(ctx,
		`SELECT project_id::text, COALESCE(org_id::text,'') FROM public.groups WHERE id::text=$1`, groupID)
	if err := row.Scan(&projectID, &orgID); err != nil {
		return "", "", false
	}
	return projectID, orgID, true
}

// scanGroup reads a groups row in the canonical column order.
func scanGroup(row rowScanner, g *Group) error {
	return row.Scan(&g.ID, &g.ProjectID, &g.OrgID, &g.Name, &g.CreatedBy, &g.CreatedAt)
}
