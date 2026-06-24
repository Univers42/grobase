/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   provision.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:39 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:40 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"context"
	"strings"
)

// tenantSchema derives the per-tenant schema name for a tenant id, mirroring the
// Rust `DatabaseMount::tenant_schema` sanitization EXACTLY (lowercase, keep
// [a-z0-9_], replace others with '_', trim '_', truncate 50, prefix `tenant_`).
// The two implementations are kept in lockstep by a shared test vector. Returns
// "" if the id sanitizes to empty.
func tenantSchema(id string) string {
	var b strings.Builder
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
			b.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r + ('a' - 'A'))
		default:
			b.WriteRune('_')
		}
	}
	frag := strings.Trim(b.String(), "_")
	if frag == "" {
		return ""
	}
	if len(frag) > 50 {
		frag = frag[:50]
	}
	return "tenant_" + frag
}

// Provision reconciles a declarative tenant stack in one idempotent call:
//  1. bootstrap the tenant + first API key + default ABAC role (idempotent);
//  2. register each requested data mount in the adapter-registry, scoped by the
//     tenant SLUG so the api-key query path can resolve it;
//  3. for schema_per_tenant postgres mounts, create the tenant schema.
//
// Re-running is safe: tenant/key/role reuse existing state, mounts report
// "exists", and CREATE SCHEMA IF NOT EXISTS is a no-op. One mount failure does
// not abort the rest — it is reported per-mount.
func (s *Service) Provision(ctx context.Context, req ProvisionRequest) (ProvisionResponse, error) {
	name := req.Name
	if name == "" {
		name = req.Tenant
	}
	bs, err := s.Bootstrap(ctx, req.Tenant, name, BootstrapRequest{
		OwnerUserID:     req.OwnerUserID,
		DefaultRoleName: req.DefaultRoleName,
		DefaultKeyName:  req.DefaultKeyName,
		SeedRoles:       req.SeedRoles,
	})
	if err != nil {
		return ProvisionResponse{}, err
	}
	out := provisionResponseFrom(bs, len(req.Mounts))
	for _, m := range req.Mounts {
		out.Mounts = append(out.Mounts, s.reconcileMount(ctx, req.Tenant, m))
	}
	return out, nil
}

// provisionResponseFrom seeds a ProvisionResponse from the bootstrap result,
// pre-sizing the Mounts slice for the requested mount count.
func provisionResponseFrom(bs BootstrapResponse, mountCap int) ProvisionResponse {
	return ProvisionResponse{
		Tenant:   bs.Tenant,
		APIKey:   bs.APIKey,
		KeyReuse: bs.KeyReuse,
		Created:  bs.Created,
		Roles:    bs.Roles,
		Mounts:   make([]MountResult, 0, mountCap),
	}
}

// reconcileMount registers one mount (slug-scoped) and, for schema_per_tenant
// postgres mounts, ensures the tenant schema exists.
func (s *Service) reconcileMount(ctx context.Context, slug string, m MountSpec) MountResult {
	res := MountResult{Engine: m.Engine, Name: m.Name}
	if s.adapter == nil {
		res.Status = "error"
		res.Error = "adapter-registry not configured (set ADAPTER_REGISTRY_URL)"
		return res
	}
	id, status, err := s.adapter.register(ctx, slug, m)
	if err != nil {
		res.Status = "error"
		res.Error = err.Error()
		s.log.Warn("provision mount register failed", "tenant", slug, "engine", m.Engine, "name", m.Name, "err", err)
		return res
	}
	res.Status = status
	res.ID = id
	if strings.EqualFold(m.Isolation, "schema_per_tenant") {
		s.reconcileSchema(ctx, slug, m, &res)
	}
	return res
}

// reconcileSchema ensures the per-tenant schema for a schema_per_tenant postgres
// mount, stamping res.Schema on success or res.Error on any failure.
func (s *Service) reconcileSchema(ctx context.Context, slug string, m MountSpec, res *MountResult) {
	if m.Engine != "postgresql" {
		res.Error = "schema_per_tenant is only supported for postgresql mounts"
		return
	}
	schema := tenantSchema(slug)
	switch {
	case schema == "":
		res.Error = "tenant slug sanitizes to an empty schema name"
	case s.dataPlane == nil:
		res.Error = "data-plane not configured (set RUST_DATA_PLANE_URL); schema not created"
	default:
		if serr := s.dataPlane.ensureSchema(ctx, slug, schema, m); serr != nil {
			res.Error = "mount registered but schema create failed: " + serr.Error()
			s.log.Warn("provision schema create failed", "tenant", slug, "schema", schema, "err", serr)
		} else {
			res.Schema = schema
		}
	}
}
