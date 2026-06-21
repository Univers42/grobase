/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   resolver.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:48 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:49 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package entitlements

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
)

// Resolver is THE single swap point of the dynamic builder. Everywhere the
// control plane resolves a tenant's effective package it calls Resolve(slug,
// plan); the result is a packages.Package whose methods (CapabilityOverrides,
// QueryCountCap, AllowsEngine, PoolPolicy) the stamp / quota guard / engine
// allowlist / rate limiter consume UNCHANGED.
//
// Resolution:
//
//	BUILDER_ENABLED OFF (resolver nil/disabled) ─► manifest.For(plan) verbatim   (PARITY)
//	no entitlement row (ErrNotFound)            ─► manifest.For(plan) verbatim   (PARITY)
//	status != "active" (e.g. "draft")           ─► manifest.For(plan) verbatim   (PARITY)
//	active row                                   ─► Clamp(custom, For(ceiling))   (BUILDER)
//
// where the ceiling tier is the operator's ceiling_plan when set, else the
// tenant's own plan. The CLAMP is the load-bearing backstop: an entitlement row
// written over the ceiling (operator set it high, tenant later downgraded) is
// clamped DOWN on EVERY resolve, never trusted. The returned NAME is the ceiling
// tier name (informational, e.g. for the /connect "package" field) — the
// EFFECTIVE shape is the clamped package.
type Resolver struct {
	manifest *packages.Manifest
	loader   Loader
	enabled  bool
	log      *slog.Logger
}

// NewResolver builds a resolver. enabled gates the whole feature (BUILDER_ENABLED
// from main.go). When enabled is false (or the loader is nil), Resolve degrades to
// manifest.For — byte-parity. The manifest must be non-nil (tiering is a security
// boundary); the caller loads it once at boot. loader is the read seam (the *Store
// in production, a fake in tests).
func NewResolver(manifest *packages.Manifest, loader Loader, enabled bool, log *slog.Logger) *Resolver {
	return &Resolver{manifest: manifest, loader: loader, enabled: enabled && loader != nil, log: log}
}

// Enabled reports whether the builder resolver is active (BUILDER_ENABLED + a
// loader). When false, every Resolve is manifest.For(plan) verbatim.
func (r *Resolver) Enabled() bool { return r != nil && r.enabled }

// Resolve returns the tenant's EFFECTIVE package + the resolved tier name.
//
// A nil *Resolver, a disabled one, an unreadable/absent row, or a non-active row
// ALL fall back to manifest.For(plan) — the parity contract. Only an ACTIVE row
// applies the custom overlay, and even then the result is Clamp(custom, ceiling)
// so it can never exceed the ceiling tier.
//
// A store read error is logged and treated as "no row" (fail-OPEN to the named
// tier, never fail-CLOSED on a transient DB blip — the same posture the rate
// limiter and quota guard take). It can only WIDEN to the named tier, never past
// it, so failing open is safe (the tenant gets its paid plan, not more).
func (r *Resolver) Resolve(ctx context.Context, slug, plan string) (string, packages.Package) {
	if !r.Enabled() {
		return r.manifest.For(plan)
	}
	rec, err := r.loader.Load(ctx, slug)
	if err != nil {
		if !errors.Is(err, ErrNotFound) && r.log != nil {
			r.log.Warn("entitlement load failed; resolving named tier (parity)", "tenant", slug, "err", err)
		}
		return r.manifest.For(plan)
	}
	if rec.Status != "active" {
		return r.manifest.For(plan)
	}
	return r.applyActive(rec, plan)
}

// applyActive synthesizes the effective package for an ACTIVE entitlement row.
// The ceiling tier is the operator ceiling_plan when set, else the tenant's own
// plan; manifest.For applies the alias/default chain so a stale/unknown
// ceiling_plan degrades to the safe baseline tier rather than erroring. Clamp is
// the resolve-time backstop: the result is ≤ the ceiling on every axis, no matter
// what the row holds. The returned name is the ceiling tier name (informational).
func (r *Resolver) applyActive(rec Record, plan string) (string, packages.Package) {
	ceilingPlan := plan
	if rec.CeilingPlan != "" {
		ceilingPlan = rec.CeilingPlan
	}
	ceilingName, ceiling := r.manifest.For(ceilingPlan)
	eff := packages.Clamp(rec.Entitlement.ToPackage(), ceiling)
	return ceilingName, eff
}

// Manifest exposes the underlying tier manifest (the resolver owns the single
// loaded copy). Handlers reuse it for ValidateWithin's ceiling lookup + plan
// validation without re-loading.
func (r *Resolver) Manifest() *packages.Manifest { return r.manifest }
