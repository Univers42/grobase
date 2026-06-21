/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:45 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:46 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package export

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// exportErr is the package's const error type: a string whose Error() is itself,
// so sentinels are typed consts (==-comparable, errors.Is-friendly).
type exportErr string

func (e exportErr) Error() string { return string(e) }

// ErrIsolationDeferred is returned when an export is requested for an isolation
// model D4.3 does NOT support: db_per_tenant (needs the DSN resolver, B6b-style)
// and tenant_owned (external DB). The handler maps it to 400. The deferral is
// also enforced structurally by the 052 CHECK (a row for a deferred model cannot
// be inserted).
const ErrIsolationDeferred exportErr = "isolation not supported for export (deferred)"

// ErrNoMount is returned when the tenant has no registered mount to export.
const ErrNoMount exportErr = "tenant has no registered data mount"

// ErrNotFound mirrors tenants.ErrNotFound at this package boundary (the self-serve
// read route maps it to 404).
const ErrNotFound exportErr = "tenant not found"

// Service orchestrates per-tenant data EXPORT over the shared control-plane
// Postgres (the tenant_exports ledger + schema_per_tenant / shared_rls data) and
// an ArtifactStore (where the portable bundle lands). It reuses the SAME data
// scoping the B6 backup + D4.4 erase services use (tenants.TenantSchema for
// schema_per_tenant, the shared-table discovery + tenant_id filter for
// shared_rls) so an export sees exactly one tenant's data.
type Service struct {
	db    *pg.Postgres
	store ArtifactStore
	keys  *tenants.Service // optional: credential resolution for the self-serve read route
	log   *slog.Logger
}

// NewService builds the export service.
func NewService(db *pg.Postgres, store ArtifactStore, log *slog.Logger) *Service {
	return &Service{db: db, store: store, log: log}
}

// WithTenants wires the tenants.Service used ONLY by the optional, default-OFF
// self-serve read route (/v1/tenants/me/exports) to resolve a credential to its
// owning tenant. The admin routes never consult it. Delegating to tenants.Service
// keeps the (sensitive) key-hashing scheme single-sourced — no re-implementation,
// no drift. Mirrors backup.Service.WithTenants.
func (s *Service) WithTenants(t *tenants.Service) *Service { s.keys = t; return s }

// VerifyKey resolves a raw tenant API key to its tenant slug via the
// single-source tenants verifier. Used only by the self-serve read route.
func (s *Service) VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error) {
	if s.keys == nil {
		return tenants.VerifyKeyResponse{}, fmt.Errorf("export: self-serve key verification not wired")
	}
	return s.keys.VerifyKey(ctx, raw)
}

// TenantForUser resolves a GoTrue user id to the slug of the tenant it owns.
// Used only by the self-serve read route. Mirrors backup.Service.TenantForUser.
func (s *Service) TenantForUser(ctx context.Context, userID string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT slug FROM public.tenants WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", rerr
		}
		return "", ErrNotFound
	}
	var slug string
	if err := rows.Scan(&slug); err != nil {
		return "", err
	}
	return slug, nil
}
