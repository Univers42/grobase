/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   org_crud.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:51:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:17 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package orgs

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
)

// GetOrg fetches an org by its uuid OR slug.
func (s *Service) GetOrg(ctx context.Context, idOrSlug string) (Org, error) {
	rows, err := s.db.AdminQuery(ctx, selectOrg+` WHERE id::text = $1 OR slug = $1`, idOrSlug)
	return scanOneOrgRows(rows, err)
}

// scanOneOrgRows scans the first row of rows into an Org, mapping an empty result
// to ErrNotFound. err is the AdminQuery error (passed through). It centralizes the
// "one org row or ErrNotFound" pattern GetOrg and UpdateOrg share.
func scanOneOrgRows(rows pgx.Rows, err error) (Org, error) {
	if err != nil {
		return Org{}, err
	}
	var o Org
	if err := scanOrg(&singleRow{rows: rows}, &o); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Org{}, ErrNotFound
		}
		return Org{}, err
	}
	return o, nil
}

// ListOrgsForUser returns the orgs the user is a member of.
func (s *Service) ListOrgsForUser(ctx context.Context, userID string) ([]Org, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT o.id::text, o.slug, o.name, o.plan, o.status, o.metadata::text, o.created_by,
		       o.created_at::text, o.updated_at::text
		  FROM public.orgs o
		  JOIN public.org_members m ON m.org_id = o.id
		 WHERE m.user_id = $1 AND o.status <> 'deleted'
		 ORDER BY o.created_at DESC
		 LIMIT 500`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Org, 0)
	for rows.Next() {
		var o Org
		if err := scanOrg(rows, &o); err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// UpdateOrg mutates name/metadata, keyed by org id.
func (s *Service) UpdateOrg(ctx context.Context, orgID string, req UpdateOrgRequest) (Org, error) {
	var metaArg any
	if req.Metadata != nil {
		b, _ := json.Marshal(req.Metadata)
		metaArg = string(b)
	}
	rows, err := s.db.AdminQuery(ctx, `
		UPDATE public.orgs
		   SET name     = COALESCE($2, name),
		       metadata = COALESCE($3::jsonb, metadata),
		       updated_at = now()
		 WHERE id::text = $1
		 RETURNING id::text, slug, name, plan, status, metadata::text, created_by,
		           created_at::text, updated_at::text`,
		orgID, req.Name, metaArg)
	return scanOneOrgRows(rows, err)
}

// SoftDeleteOrg sets status='deleted'. ON DELETE SET NULL on tenants.org_id is
// NOT triggered by a soft-delete (the row stays), so attached projects keep their
// org_id; a hard delete (manual) would orphan them to org-less. Keyed by org id.
func (s *Service) SoftDeleteOrg(ctx context.Context, orgID string) error {
	tag, err := s.exec(ctx,
		`UPDATE public.orgs SET status='deleted', updated_at=now()
		  WHERE id::text=$1 AND status<>'deleted'`, orgID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
