/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   provision_adapters_clients.go                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:32 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:33 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"context"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

func toTenantInfo(t Tenant) provision.TenantInfo {
	return provision.TenantInfo{
		Slug:        t.ID,
		UUID:        t.UUID,
		Name:        t.Name,
		Status:      t.Status,
		Plan:        t.Plan,
		OwnerUserID: t.OwnerUserID,
		Metadata:    t.Metadata,
	}
}

// ── MountClient adapter ──────────────────────────────────────────────────────

type mountAdapter struct{ ar *AdapterRegistry }

func (a *mountAdapter) RegisterMount(ctx context.Context, slug string, e provision.EngineSpec) (string, string, error) {
	return a.ar.register(ctx, slug, MountSpec{
		Engine:           e.Engine,
		Name:             e.Name,
		ConnectionString: e.ConnectionString,
		Isolation:        e.Isolation,
	})
}

// ── SchemaClient adapter ─────────────────────────────────────────────────────

type schemaAdapter struct{ dp *DataPlane }

func (a *schemaAdapter) EnsureSchema(ctx context.Context, slug string, e provision.EngineSpec) (string, error) {
	schema := tenantSchema(slug)
	if schema == "" {
		return "", errors.New("tenant slug sanitizes to an empty schema name")
	}
	if err := a.dp.ensureSchema(ctx, slug, schema, MountSpec{
		Engine:           e.Engine,
		Name:             e.Name,
		ConnectionString: e.ConnectionString,
		Isolation:        e.Isolation,
	}); err != nil {
		return "", err
	}
	return schema, nil
}
