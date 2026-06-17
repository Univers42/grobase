package adapterregistry

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"sync"

	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"golang.org/x/sync/singleflight"
)

// ErrNotFound is returned when a tenant database row does not exist.
var ErrNotFound = errors.New("database not found")

// ErrConflict is returned on the (tenant_id, name) unique violation.
var ErrConflict = errors.New("database already registered")

// ErrEngineNotInPackage is returned when a tenant tries to register a mount for
// an engine its package tier does not include (Phase 4).
var ErrEngineNotInPackage = errors.New("engine not included in tenant package")

// ErrMountQuotaExceeded is returned when a tenant is already at its package's
// max_mounts cap (Phase 4).
var ErrMountQuotaExceeded = errors.New("tenant has reached its package mount quota")

// ErrPlaintextDsnForbidden is returned when a tenant whose package's
// security_mode is "max" tries to register a mount with an INLINE plaintext
// connection_string (S2 / G-Vault). Such tenants must register a Vault
// credential_ref instead, so no plaintext DSN is ever encrypted-at-rest for
// them. A no-op when tiering is disabled or the tenant's tier is not max.
var ErrPlaintextDsnForbidden = errors.New("security_mode=max forbids an inline plaintext connection_string; register a credential_ref instead")

// derefStr returns the pointed-to string, or "" for a nil pointer (a NULL
// column). Used to flatten the nullable cred_* columns into the wire struct.
func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// Service implements the adapter-registry control-plane logic.
type Service struct {
	db   *shared.Postgres
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
func NewService(db *shared.Postgres, enc *Encryptor, log *slog.Logger) *Service {
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
	// Dynamic builder (BUILDER_ENABLED): when a resolver is wired, the EFFECTIVE
	// package is the tenant's custom entitlement clamped to its ceiling. When nil
	// (the default), resolve the plan via the manifest verbatim — byte-parity.
	// Both return a packages.Package, so the AllowsEngine gate, the MaxMounts cap,
	// and the CapabilityOverrides stamp are identical downstream.
	if s.resolver != nil {
		name, pkg := s.resolver.Resolve(ctx, tenantSlug, plan)
		return name, pkg, true
	}
	name, pkg := s.pkgs.For(plan)
	return name, pkg, true
}

// EnsureSchema creates public.tenant_databases idempotently. The live schema
// has tenant_id as TEXT (set by migration 005 + 030 in the TS days); we
// preserve that here since changing column type would require a destructive
// migration. The fresh-install shape uses TEXT to stay aligned.
//
// Tenant policy: M12 retired the pre-existing 'tenant_isolation' policy that
// compared `tenant_id` against `auth.current_user_id()` (i.e. treated every
// user as their own tenant). The corrected policy uses
// `auth.current_tenant_id()` and is named `tenant_databases_tenant_isolation`
// to avoid collision with the legacy name. We drop the old name on upgrade.
func (s *Service) EnsureSchema(ctx context.Context) error {
	const ddl = `
CREATE TABLE IF NOT EXISTS public.tenant_databases (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       TEXT NOT NULL,
  engine          TEXT NOT NULL CHECK (engine IN ('postgresql','cockroachdb','mongodb','mysql','mariadb','redis','sqlite','mssql','http','jdbc','cassandra','neo4j','elasticsearch','qdrant','influx')),
  name            TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
  connection_enc  BYTEA NOT NULL,
  connection_iv   BYTEA NOT NULL,
  connection_tag  BYTEA NOT NULL,
  connection_salt BYTEA,
  created_at      TIMESTAMPTZ DEFAULT now(),
  last_healthy_at TIMESTAMPTZ,
  isolation       TEXT NOT NULL DEFAULT 'shared_rls' CHECK (isolation IN ('shared_rls','schema_per_tenant','db_per_tenant','tenant_owned')),
  UNIQUE (tenant_id, name)
);
-- Additive for pre-existing tables (the CHECK above only applies to fresh installs).
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS isolation TEXT NOT NULL DEFAULT 'shared_rls';
-- Idempotently widen the fresh-install CHECK on upgraded databases so
-- tenant_owned mounts register (older installs baked the 3-value list).
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_isolation_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_isolation_check
  CHECK (isolation IN ('shared_rls','schema_per_tenant','db_per_tenant','tenant_owned'));
-- Idempotently widen the engine CHECK so newer engine ids (mariadb,
-- cockroachdb, mssql) register on upgraded databases (older installs baked a
-- narrower engine list). The broad set stays at the DB layer; control-plane
-- allowedEngines is the honest ACCEPT gate (only engines with a live Rust pool).
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_engine_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_engine_check
  CHECK (engine IN ('postgresql','cockroachdb','mongodb','mysql','mariadb','redis','sqlite','mssql','http','jdbc','cassandra','neo4j','elasticsearch','qdrant','influx'));
-- S2 / G-Vault (migration 060, mirrored here so a FRESH EnsureSchema install
-- converges with a migrated one): a mount may carry a Vault credential REFERENCE
-- instead of an inline encrypted DSN. Add the three nullable cred_* columns,
-- make the inline-encrypted columns nullable, and enforce EXACTLY ONE of
-- {inline-encrypted, cred-ref} per row. All idempotent; existing inline rows are
-- untouched (they remain inline_complete).
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_provider  TEXT;
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_reference TEXT;
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_version   TEXT;
ALTER TABLE public.tenant_databases ALTER COLUMN connection_enc DROP NOT NULL;
ALTER TABLE public.tenant_databases ALTER COLUMN connection_iv  DROP NOT NULL;
ALTER TABLE public.tenant_databases ALTER COLUMN connection_tag DROP NOT NULL;
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_credential_xor_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_credential_xor_check CHECK (
  (connection_enc IS NOT NULL AND connection_iv IS NOT NULL AND connection_tag IS NOT NULL
     AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL)
  OR
  (cred_provider IS NOT NULL AND cred_reference IS NOT NULL
     AND connection_enc IS NULL AND connection_iv IS NULL AND connection_tag IS NULL
     AND connection_salt IS NULL)
);
-- CMEK / BYOK (migration 061, mirrored here so a FRESH EnsureSchema install
-- converges with a migrated one): add the two nullable cmek_* columns, DROP the
-- 060 two-way XOR check, and ADD a THREE-way check admitting a third mode —
-- cmek-envelope (enc/iv/tag + cmek_wrapped_dek + cmek_kms_key_id, cred_* NULL).
-- The cmek_* columns are NULL on every inline / cred-ref row, so the baseline is
-- untouched. With CMEK_ENABLED OFF (default) mode (iii) is never written.
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cmek_wrapped_dek BYTEA;
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cmek_kms_key_id  TEXT;
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_credential_xor_check;
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_credential_mode_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_credential_mode_check CHECK (
  (connection_enc IS NOT NULL AND connection_iv IS NOT NULL AND connection_tag IS NOT NULL
     AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL
     AND cmek_wrapped_dek IS NULL AND cmek_kms_key_id IS NULL)
  OR
  (cred_provider IS NOT NULL AND cred_reference IS NOT NULL
     AND connection_enc IS NULL AND connection_iv IS NULL AND connection_tag IS NULL
     AND connection_salt IS NULL
     AND cmek_wrapped_dek IS NULL AND cmek_kms_key_id IS NULL)
  OR
  (connection_enc IS NOT NULL AND connection_iv IS NOT NULL AND connection_tag IS NOT NULL
     AND cmek_wrapped_dek IS NOT NULL AND cmek_kms_key_id IS NOT NULL
     AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL)
);
ALTER TABLE public.tenant_databases ENABLE ROW LEVEL SECURITY;
-- Retire the pre-M12 broken policy on upgrade.
DROP POLICY IF EXISTS tenant_isolation ON public.tenant_databases;
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'tenant_databases' AND policyname = 'tenant_databases_tenant_isolation'
  ) THEN
    CREATE POLICY tenant_databases_tenant_isolation ON public.tenant_databases
      FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
      WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
  END IF;
END $$;`
	return s.db.AdminExec(ctx, ddl)
}
