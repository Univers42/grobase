/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   tenant_update.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:06 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
)

// updateTenant patches the COALESCE-present fields keyed by slug.
const updateTenant = `
	WITH updated AS (
	  UPDATE public.tenants
	     SET name     = COALESCE($2, name),
	         plan     = COALESCE($3, plan),
	         status   = COALESCE($4, status),
	         metadata = COALESCE($5::jsonb, metadata)
	   WHERE slug = $1
	   RETURNING id, slug, name, status, plan, owner_user_id, metadata, created_at, updated_at
	)
	SELECT id::text, slug, name, status, plan, owner_user_id, metadata::text,
	       created_at::text, updated_at::text FROM updated`

// Update mutates the fields present in the request, keyed by slug.
func (s *Service) Update(ctx context.Context, slug string, req UpdateTenantRequest) (Tenant, error) {
	var metaArg any
	if req.Metadata != nil {
		b, _ := json.Marshal(req.Metadata)
		metaArg = string(b)
	}
	row, err := s.queryOne(ctx, updateTenant, slug, req.Name, req.Plan, req.Status, metaArg)
	if err != nil {
		return Tenant{}, err
	}
	var t Tenant
	if err := scanTenant(row, &t); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Tenant{}, ErrNotFound
		}
		return Tenant{}, err
	}
	return t, nil
}
