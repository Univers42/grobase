/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   provision_adapters.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:34 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

// This file is the seam between the tenants package (concrete services) and the
// provision package (the declarative reconciler, which depends only on
// interfaces). It adapts *Service / *AdapterRegistry / *DataPlane to the
// provision interfaces and builds a ready Reconciler. tenant-control wires it.

// BuildReconciler constructs a provision.Reconciler from the tenant service and
// its optional clients. perm is the shared ABAC seam; if nil the service's own
// seam is reused so there is exactly one role implementation. lockDB enables the
// Postgres advisory-lock concurrency guard.
func (s *Service) BuildReconciler(perm provision.PermissionEngine, log *slog.Logger) *provision.Reconciler {
	if perm == nil {
		perm = s.perm
	}
	rc := &provision.Reconciler{
		Tenants: &tenantSvcAdapter{svc: s},
		Perm:    perm,
		Lock:    provision.NewPGLocker(s.db),
		Log:     log,
	}
	if s.adapter != nil {
		rc.Mounts = &mountAdapter{ar: s.adapter}
	}
	if s.dataPlane != nil {
		rc.Schemas = &schemaAdapter{dp: s.dataPlane}
	}
	return rc
}

// ── TenantService adapter ────────────────────────────────────────────────────

type tenantSvcAdapter struct{ svc *Service }

func (a *tenantSvcAdapter) GetTenant(ctx context.Context, slug string) (provision.TenantInfo, bool, error) {
	t, err := a.svc.FindOne(ctx, slug)
	if errors.Is(err, ErrNotFound) {
		return provision.TenantInfo{}, false, nil
	}
	if err != nil {
		return provision.TenantInfo{}, false, err
	}
	return toTenantInfo(t), true, nil
}

// CreateTenant creates the tenant or returns the existing one. It delegates to
// findOrCreateBySlug, which maps the create/conflict race to a clean fetch,
// keeping CreateTenant idempotent under concurrency.
func (a *tenantSvcAdapter) CreateTenant(ctx context.Context, slug, name, ownerUserID, plan string) (provision.TenantInfo, error) {
	t, _, err := a.svc.findOrCreateBySlug(ctx, slug, name, ownerUserID, plan)
	if err != nil {
		return provision.TenantInfo{}, err
	}
	return toTenantInfo(t), nil
}

func (a *tenantSvcAdapter) ActiveKeyExists(ctx context.Context, slug, keyName string) (bool, error) {
	k, err := a.svc.findActiveKeyByName(ctx, slug, keyName)
	if err != nil {
		return false, err
	}
	return k != nil, nil
}

func (a *tenantSvcAdapter) IssueAPIKey(ctx context.Context, slug string, k provision.KeySpec) (provision.KeyInfo, error) {
	out, err := a.svc.IssueKey(ctx, slug, IssueKeyRequest{
		Name:      k.Name,
		Scopes:    k.Scopes,
		ExpiresAt: k.ExpiresAt,
	})
	if err != nil {
		return provision.KeyInfo{}, err
	}
	return provision.KeyInfo{
		ID:        out.ID,
		Name:      out.Name,
		KeyPrefix: out.KeyPrefix,
		Scopes:    out.Scopes,
		Key:       out.Key,
	}, nil
}
