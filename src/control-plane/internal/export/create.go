/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   create.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:17 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package export

import (
	"context"
	"fmt"
)

// isolationFor resolves the isolation model for the tenant from
// public.tenant_databases (tenant_id ALWAYS a bind param — the cross-tenant
// wall). When the tenant has multiple mounts they must share one isolation model
// for a whole-tenant export; the first row's isolation is authoritative (mirrors
// erase.scopeFor). An empty mount means whole-tenant; a named mount narrows the
// lookup. Returns ErrNoMount when there is no row.
func (s *Service) isolationFor(ctx context.Context, tenantID, mount string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT isolation FROM public.tenant_databases
		  WHERE tenant_id = $1 AND ($2 = '' OR name = $2)
		  ORDER BY created_at LIMIT 1`, tenantID, mount)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", rerr
		}
		return "", ErrNoMount
	}
	var iso string
	if err := rows.Scan(&iso); err != nil {
		return "", err
	}
	return iso, nil
}

// guardIsolation rejects the isolation models D4.3 does not support. Only
// schema_per_tenant and shared_rls are exportable in the MVP.
func guardIsolation(iso string) error {
	switch iso {
	case "schema_per_tenant", "shared_rls":
		return nil
	default:
		return ErrIsolationDeferred
	}
}

// insertPending records a new export row in 'pending' state and returns its id.
// tenant_id, mount, isolation are bind params; an empty mount stores NULL.
func (s *Service) insertPending(ctx context.Context, tenantID, mount, iso string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`INSERT INTO public.tenant_exports (tenant_id, mount, isolation, engine, format, location, status)
		 VALUES ($1, NULLIF($2,''), $3, 'postgresql', 'json', '', 'pending')
		 RETURNING id::text`, tenantID, mount, iso)
	if err != nil {
		return "", fmt.Errorf("export: insert ledger row: %w", err)
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", fmt.Errorf("export: insert ledger row: %w", rerr)
		}
		return "", fmt.Errorf("export: insert ledger row returned no id")
	}
	var id string
	if err := rows.Scan(&id); err != nil {
		return "", fmt.Errorf("export: scan inserted id: %w", err)
	}
	return id, nil
}

// CreateExport produces a PORTABLE bundle of ONE tenant's data and records it.
// Flow: resolve+guard isolation -> INSERT status='pending' -> stream bundle into
// the store (which tees size+sha256) -> UPDATE status='completed' (manifest /
// counts / sha) or 'failed'. Returns the export id. tenant_id is always a bind
// param, and the SELECTs are scoped to the tenant's own schema / WHERE tenant_id,
// so the bundle can NEVER contain another tenant's rows.
func (s *Service) CreateExport(ctx context.Context, tenantID, mount string) (string, error) {
	iso, err := s.isolationFor(ctx, tenantID, mount)
	if err != nil {
		return "", err
	}
	if err := guardIsolation(iso); err != nil {
		return "", err
	}

	exportID, err := s.insertPending(ctx, tenantID, mount, iso)
	if err != nil {
		return "", err
	}

	key := tenantID + "/" + exportID
	manifest, location, size, sha, xerr := s.extractTo(ctx, iso, tenantID, key)
	if xerr != nil {
		s.markFailed(ctx, exportID, xerr)
		return exportID, xerr
	}
	if uerr := s.markCompleted(ctx, completion{exportID: exportID, manifest: manifest, location: location, size: size, sha: sha}); uerr != nil {
		return exportID, uerr
	}
	return exportID, nil
}
