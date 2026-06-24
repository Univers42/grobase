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

package environments

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// crud.go — environment lifecycle, all project-bounded (every query filters project_id).

const selectEnv = `SELECT id::text, project_id::text, name, created_by, created_at::text,
       scope_pubkey, scope_epoch FROM public.environments`

// CreateEnvironment inserts a (project, name) environment; a duplicate → ErrConflict.
func (s *Service) CreateEnvironment(ctx context.Context, projectID, name, actor string) (Environment, error) {
	var e Environment
	row := s.db.AdminQueryRow(ctx, `
		INSERT INTO public.environments (project_id, name, created_by)
		VALUES ($1::uuid, $2, NULLIF($3,''))
		RETURNING id::text, project_id::text, name, created_by, created_at::text, scope_pubkey, scope_epoch`,
		projectID, name, actor)
	if err := scanEnv(row, &e); err != nil {
		if pg.IsUniqueViolation(err) {
			return Environment{}, ErrConflict
		}
		return Environment{}, err
	}
	return e, nil
}

// GetEnvironment reads one environment by id within projectID (ErrNotFound when absent).
func (s *Service) GetEnvironment(ctx context.Context, projectID, envID string) (Environment, error) {
	var e Environment
	row := s.db.AdminQueryRow(ctx, selectEnv+` WHERE id::text=$1 AND project_id::text=$2`, envID, projectID)
	if err := scanEnv(row, &e); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Environment{}, ErrNotFound
		}
		return Environment{}, err
	}
	return e, nil
}

// ListEnvironments returns a project's environments, name-ordered.
func (s *Service) ListEnvironments(ctx context.Context, projectID string) ([]Environment, error) {
	rows, err := s.db.AdminQuery(ctx, selectEnv+` WHERE project_id::text=$1 ORDER BY name`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Environment, 0)
	for rows.Next() {
		var e Environment
		if err := scanEnv(rows, &e); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// DeleteEnvironment removes an environment within projectID (ErrNotFound when absent). Its
// env-scoped grants cascade (project_grants.env_id ON DELETE CASCADE, migration 079).
func (s *Service) DeleteEnvironment(ctx context.Context, projectID, envID string) error {
	var id string
	row := s.db.AdminQueryRow(ctx,
		`DELETE FROM public.environments WHERE id::text=$1 AND project_id::text=$2 RETURNING id::text`,
		envID, projectID)
	if err := row.Scan(&id); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	return nil
}

// SetScopeKey publishes (or rotates) the env's vault42 scope PUBLIC key + epoch (ErrNotFound
// when the env is absent in projectID).
func (s *Service) SetScopeKey(ctx context.Context, projectID, envID, pubkey string, epoch int) (Environment, error) {
	var e Environment
	row := s.db.AdminQueryRow(ctx, `
		UPDATE public.environments SET scope_pubkey=$3, scope_epoch=$4
		 WHERE id::text=$1 AND project_id::text=$2
		RETURNING id::text, project_id::text, name, created_by, created_at::text, scope_pubkey, scope_epoch`,
		envID, projectID, pubkey, epoch)
	if err := scanEnv(row, &e); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Environment{}, ErrNotFound
		}
		return Environment{}, err
	}
	return e, nil
}
