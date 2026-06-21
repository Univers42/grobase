/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:09 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"context"
	"log/slog"
	"os"
	"sync"

	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"golang.org/x/sync/singleflight"
)

// adapterregistryErr is the package's const error type, so every sentinel is a
// typed constant (no package-level var) while preserving errors.Is matching.
type adapterregistryErr string

func (e adapterregistryErr) Error() string { return string(e) }

// ErrNotFound is returned when a tenant database row does not exist.
const ErrNotFound adapterregistryErr = "database not found"

// ErrConflict is returned on the (tenant_id, name) unique violation.
const ErrConflict adapterregistryErr = "database already registered"

// ErrEngineNotInPackage is returned when a tenant tries to register a mount for
// an engine its package tier does not include (Phase 4).
const ErrEngineNotInPackage adapterregistryErr = "engine not included in tenant package"

// ErrMountQuotaExceeded is returned when a tenant is already at its package's
// max_mounts cap (Phase 4).
const ErrMountQuotaExceeded adapterregistryErr = "tenant has reached its package mount quota"

// ErrPlaintextDsnForbidden is returned when a tenant whose package's
// security_mode is "max" tries to register a mount with an INLINE plaintext
// connection_string (S2 / G-Vault). Such tenants must register a Vault
// credential_ref instead, so no plaintext DSN is ever encrypted-at-rest for
// them. A no-op when tiering is disabled or the tenant's tier is not max.
const ErrPlaintextDsnForbidden adapterregistryErr = "security_mode=max forbids an inline plaintext connection_string; register a credential_ref instead"

// Service implements the adapter-registry control-plane logic.
type Service struct {
	db   *pg.Postgres
	enc  *Encryptor
	log  *slog.Logger
	pkgs *packages.Manifest
	// enforce gates package tiering (engine allowlist + mount quota +
	// capability_overrides on /connect). Defaults OFF (opt-in via
	// PACKAGE_ENFORCEMENT=1) so enabling tiering NEVER retroactively gates
	// existing `free` tenants — the shadow→cutover discipline: the capability
	// ships dormant (parity), the operator turns it on once tenant plans are
	// set. When OFF, /connect emits no mask and registration gates nothing.
	enforce bool
	// connCache short-circuits the per-record scrypt KDF (N=16384, ~50-100ms
	// CPU) in Decrypt on the hot /connect path: under 200-tenant fan-out the
	// per-call KDF convoyed the service to 100s+ responses (m39). Keyed by db
	// id and validated against the ciphertext auth tag, which changes whenever
	// the stored payload changes — re-registration self-invalidates, deletes
	// 404 before the cache is consulted. The tenant-ownership check and the
	// health stamp still run per call; only the KDF+decrypt is skipped.
	connCache sync.Map // db id (string) → connCacheEntry
	// sf coalesces concurrent cache misses for the SAME mount into one
	// Decrypt: a cold fan-out otherwise stampedes N identical scrypt runs
	// before the first can populate the cache. Concurrency across DISTINCT
	// mounts is already bounded inside the Encryptor (crypto.go scryptSlots,
	// SCRYPT_MAX_CONCURRENT) — the memory bound that stopped the 2026-06-11
	// bulk-registration OOM loop.
	sf singleflight.Group
	// CMEK / BYOK (D4.8) — all OFF by default (cmekEnabled=false, kms=nil), so
	// Register/GetConnection take the EXACT existing inline / cred-ref paths,
	// byte-identical to the m121/S2 baseline. Set via SetCMEK from main.go when
	// CMEK_ENABLED is on. When enabled and an INLINE mount is registered with a
	// kms_key_id (or the default), the DSN is envelope-sealed: a fresh DEK
	// encrypts it (reusing connection_enc/iv/tag) and the KMS WRAPS the DEK into
	// cmek_wrapped_dek. GetConnection unwraps via the KMS and caches by the
	// ciphertext tag exactly like the inline path (one KMS round-trip per
	// ciphertext, NOT per request). CMEK NEVER enters the data plane / pool key.
	cmekEnabled      bool
	kms              cmek.KMSProvider
	cmekDefaultKeyID string
	// resolver is the OPTIONAL dynamic-builder resolver (BUILDER_ENABLED). When
	// nil (the default) packageForTenant resolves the tenant's plan through
	// s.pkgs.For verbatim — byte-parity with the pre-builder baseline. When set
	// (wired from main.go under BUILDER_ENABLED), packageForTenant routes through
	// it so the EFFECTIVE (custom-overlaid, ceiling-clamped) package is what gets
	// stamped as capability_overrides + enforced for the engine allowlist /
	// max_mounts. The resolver returns the SAME packages.Package type, so the
	// stamp, the AllowsEngine gate, and the MaxMounts cap all work UNCHANGED.
	resolver packageResolver
}

// packageResolver is the minimal resolve seam the service needs (the dynamic
// builder's *entitlements.Resolver satisfies it). Kept as a local interface so
// the adapter-registry has NO hard dependency on the builder package and the nil
// default is a trivial byte-parity path.
type packageResolver interface {
	Resolve(ctx context.Context, slug, plan string) (string, packages.Package)
}

// SetResolver wires the dynamic-builder resolver (BUILDER_ENABLED). A no-op
// contract: pass nil (the default) to keep packageForTenant resolving the tenant
// plan via s.pkgs.For verbatim (parity). When set, the EFFECTIVE per-tenant
// package (custom entitlement clamped to its ceiling) is what is stamped/enforced.
func (s *Service) SetResolver(r packageResolver) { s.resolver = r }

// SetCMEK enables CMEK / BYOK envelope encryption for inline mounts (D4.8). A no-
// op contract: pass enabled=false (or kms=nil) to keep the existing inline /
// cred-ref behavior byte-identical (parity). When enabled, kms is the external
// KMS that wraps/unwraps the per-mount DEK and defaultKeyID is the KEK used when
// a register request omits kms_key_id. Called once at boot from main.go.
func (s *Service) SetCMEK(enabled bool, kms cmek.KMSProvider, defaultKeyID string) {
	s.cmekEnabled = enabled && kms != nil
	s.kms = kms
	s.cmekDefaultKeyID = defaultKeyID
}

// connCacheEntry pins the decrypted DSN to the exact ciphertext (auth tag)
// it came from.
type connCacheEntry struct {
	tag  string
	conn string
}

// NewService wires the store dependencies. The package manifest is loaded once
// (embedded, so this never touches the filesystem); a manifest-load failure is
// logged and tiering degrades to OFF (fail-open to parity, never fail-closed on
// a config bug — a broken manifest must not take the data path down).
func NewService(db *pg.Postgres, enc *Encryptor, log *slog.Logger) *Service {
	s := &Service{db: db, enc: enc, log: log, enforce: os.Getenv("PACKAGE_ENFORCEMENT") == "1"}
	m, err := packages.Load()
	if err != nil {
		log.Warn("package manifest load failed; tiering disabled", "error", err)
		s.enforce = false
		return s
	}
	s.pkgs = m
	return s
}

// packageForTenant resolves a tenant slug to its (name, package) via the
// tenant's `plan` column. Returns ok=false when tiering is disabled or the
// manifest is unavailable, so callers cleanly skip enforcement (parity).
//
// Dynamic builder (BUILDER_ENABLED): when a resolver is wired, the EFFECTIVE
// package is the tenant's custom entitlement clamped to its ceiling. When nil
// (the default), the plan resolves via the manifest verbatim — byte-parity.
// Both return a packages.Package, so the AllowsEngine gate, the MaxMounts cap,
// and the CapabilityOverrides stamp are identical downstream.
func (s *Service) packageForTenant(ctx context.Context, tenantSlug string) (string, packages.Package, bool) {
	if !s.enforce || s.pkgs == nil {
		return "", packages.Package{}, false
	}
	var plan string
	rows, err := s.db.AdminQuery(ctx, `SELECT plan FROM public.tenants WHERE slug = $1`, tenantSlug)
	if err == nil {
		defer rows.Close()
		if rows.Next() {
			_ = rows.Scan(&plan)
		}
	} else {
		s.log.Warn("package lookup failed; treating as default tier", "tenant", tenantSlug, "error", err)
	}
	if s.resolver != nil {
		name, pkg := s.resolver.Resolve(ctx, tenantSlug, plan)
		return name, pkg, true
	}
	name, pkg := s.pkgs.For(plan)
	return name, pkg, true
}
