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

package environments

import (
	"context"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// rowScanner is the minimal single-row read surface (satisfied by pgx.Row and pgx.Rows).
type rowScanner interface{ Scan(dest ...any) error }

// Service owns environment CRUD over the admin (BYPASSRLS) pool; the Go capability gate is
// the first wall, the RLS policies the second. Dependencies are injected (no globals).
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool and a logger.
func NewService(db *pg.Postgres, log *slog.Logger) *Service { return &Service{db: db, log: log} }

// projectMeta resolves a project's org id (orgID="" ⇒ standalone) and whether it exists.
func (s *Service) projectMeta(ctx context.Context, projectID string) (orgID string, exists bool) {
	row := s.db.AdminQueryRow(ctx, `SELECT COALESCE(org_id::text,'') FROM public.tenants WHERE id::text=$1`, projectID)
	if err := row.Scan(&orgID); err != nil {
		return "", false
	}
	return orgID, true
}

// scanEnv reads an environments row in the canonical column order.
func scanEnv(row rowScanner, e *Environment) error {
	return row.Scan(&e.ID, &e.ProjectID, &e.Name, &e.CreatedBy, &e.CreatedAt,
		&e.ScopePubkey, &e.ScopeEpoch)
}
