package adapterregistry

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"

	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
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

// Register stores a mount under tenant RLS. An INLINE mount encrypts the
// connection string at rest (today's path, byte-for-byte). A cred-ref mount (S2)
// stores cred_provider/cred_reference/cred_version with NO encryption — the data
// plane resolves the real DSN at query time via its CredentialProvider registry.
func (s *Service) Register(ctx context.Context, userID string, req RegisterDatabaseRequest) (RegisterResult, error) {
	isolation := req.Isolation
	if isolation == "" {
		isolation = "shared_rls"
	}

	// Phase 4 tiering: the engine must be in the tenant's package, and the
	// tenant must be under its package's max_mounts cap. A no-op when
	// PACKAGE_ENFORCEMENT=0 / manifest unavailable.
	_, pkg, tiered := s.packageForTenant(ctx, userID)
	if tiered && !pkg.AllowsEngine(req.Engine) {
		return RegisterResult{}, fmt.Errorf("%w: %q (package allows %v)", ErrEngineNotInPackage, req.Engine, pkg.Engines)
	}

	usingRef := req.CredentialRef.set()

	// CMEK / BYOK (D4.8): an inline mount is sealed via the external KMS envelope
	// when CMEK is enabled AND a key id is in play (request kms_key_id, else the
	// env default). cred-ref mounts NEVER use CMEK (they store no ciphertext).
	// When CMEK is disabled / no key id resolves, usingCMEK stays false and the
	// EXACT existing inline path runs (byte-parity baseline). Computed BEFORE the
	// S2 max-tier check because CMEK is a valid non-plaintext-at-rest path: the
	// DSN is only recoverable with the customer's KMS key, so a max-tier tenant
	// may use it (the thing S2 forbids is platform-recoverable plaintext at rest).
	cmekKeyID := req.KMSKeyID
	if cmekKeyID == "" {
		cmekKeyID = s.cmekDefaultKeyID
	}
	usingCMEK := s.cmekEnabled && !usingRef && cmekKeyID != ""

	// S2 / G-Vault: a tenant whose tier's security_mode is "max" may NOT register
	// an inline plaintext DSN under the PLATFORM master key — it must use a
	// credential_ref OR a CMEK envelope so no platform-recoverable plaintext is
	// encrypted-at-rest for it. Gated on the resolved tier; a no-op when tiering
	// is disabled or the tier is not max (parity for every non-max tenant), and
	// exempted when the inline DSN will be CMEK-sealed.
	if tiered && !usingRef && !usingCMEK && pkg.SecurityMode == "max" {
		return RegisterResult{}, ErrPlaintextDsnForbidden
	}

	// Encrypt ONLY for an inline path. A cred-ref mount stores no ciphertext, so
	// it never pays (nor risks) the scrypt KDF / AES-GCM seal. The inline path is
	// either the platform-master-key seal (today) or the CMEK envelope seal: both
	// fill connection_enc/iv/tag; CMEK additionally yields a wrapped DEK + key id.
	var (
		payload  EncryptedPayload
		cmekWrap []byte
	)
	switch {
	case usingCMEK:
		wrapped, iv, ct, sErr := cmek.Seal(ctx, s.kms, cmekKeyID, []byte(req.ConnectionString))
		if sErr != nil {
			return RegisterResult{}, fmt.Errorf("cmek seal: %w", sErr)
		}
		enc, tag, spErr := cmek.SplitCiphertext(ct)
		if spErr != nil {
			return RegisterResult{}, spErr
		}
		// Reuse the inline columns: enc/iv/tag carry the DEK-encrypted DSN. No
		// scrypt salt (CMEK has no KDF), so connection_salt stays NULL.
		payload = EncryptedPayload{Encrypted: enc, IV: iv, Tag: tag}
		cmekWrap = wrapped
	case !usingRef:
		var err error
		payload, err = s.enc.Encrypt(req.ConnectionString)
		if err != nil {
			return RegisterResult{}, err
		}
	}

	var out RegisterResult
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		// Mount-quota check INSIDE the tx so the count is consistent with the
		// insert (no TOCTOU under concurrent registrations).
		if tiered && pkg.PoolPolicy.MaxMounts > 0 {
			var count int
			if err := tx.QueryRow(ctx,
				`SELECT count(*) FROM public.tenant_databases WHERE tenant_id = $1`, userID).Scan(&count); err != nil {
				return err
			}
			if count >= pkg.PoolPolicy.MaxMounts {
				return ErrMountQuotaExceeded
			}
		}
		if usingRef {
			// Cred-ref row: NULL inline-encrypted columns, populated cred_*.
			// version may be empty (NULL) — the data plane treats absent as latest.
			var version any
			if req.CredentialRef.Version != "" {
				version = req.CredentialRef.Version
			}
			row := tx.QueryRow(ctx,
				`INSERT INTO public.tenant_databases
				   (tenant_id, engine, name, cred_provider, cred_reference, cred_version, isolation)
				 VALUES ($1,$2,$3,$4,$5,$6,$7)
				 RETURNING id, engine, name, created_at::text`,
				userID, req.Engine, req.Name,
				req.CredentialRef.Provider, req.CredentialRef.Reference, version, isolation,
			)
			return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
		}
		if usingCMEK {
			// CMEK-envelope row: DEK-encrypted DSN in enc/iv/tag (NO salt — no KDF)
			// + the KMS-wrapped DEK + the KMS key id. cred_* stay NULL. The 3-way
			// DB check (migration 061 / EnsureSchema) enforces this exact shape.
			row := tx.QueryRow(ctx,
				`INSERT INTO public.tenant_databases
				   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag,
				    cmek_wrapped_dek, cmek_kms_key_id, isolation)
				 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
				 RETURNING id, engine, name, created_at::text`,
				userID, req.Engine, req.Name,
				payload.Encrypted, payload.IV, payload.Tag, cmekWrap, cmekKeyID, isolation,
			)
			return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
		}
		row := tx.QueryRow(ctx,
			`INSERT INTO public.tenant_databases
			   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, connection_salt, isolation)
			 VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
			 RETURNING id, engine, name, created_at::text`,
			userID, req.Engine, req.Name,
			payload.Encrypted, payload.IV, payload.Tag, payload.Salt, isolation,
		)
		return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
	})
	if errors.Is(err, ErrMountQuotaExceeded) {
		return RegisterResult{}, err
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return RegisterResult{}, ErrConflict
		}
		return RegisterResult{}, err
	}
	return out, nil
}

// List returns tenant database metadata, newest first.
func (s *Service) List(ctx context.Context, userID string) ([]TenantDatabase, error) {
	out := make([]TenantDatabase, 0)
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		// Defense-in-depth: bind tenant_id EXPLICITLY (atop RLS), so isolation never
		// depends on the DB role / RLS being active — a self-serve /me/mounts caller
		// must only ever see its OWN mounts even if the connection bypasses RLS.
		rows, err := tx.Query(ctx,
			`SELECT id::text, tenant_id::text, engine, name, created_at::text, last_healthy_at::text
			   FROM public.tenant_databases
			  WHERE tenant_id = $1
			  ORDER BY created_at DESC`, userID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var d TenantDatabase
			if err := rows.Scan(&d.ID, &d.TenantID, &d.Engine, &d.Name, &d.CreatedAt, &d.LastHealthyAt); err != nil {
				return err
			}
			out = append(out, d)
		}
		return rows.Err()
	})
	return out, err
}

// FindOne returns a single tenant database metadata row.
func (s *Service) FindOne(ctx context.Context, userID, id string) (TenantDatabase, error) {
	var d TenantDatabase
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx,
			`SELECT id::text, tenant_id::text, engine, name, created_at::text, last_healthy_at::text
			   FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2`, id, userID)
		err := row.Scan(&d.ID, &d.TenantID, &d.Engine, &d.Name, &d.CreatedAt, &d.LastHealthyAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return d, err
}

// GetConnection returns the connection info for the data plane. For an INLINE
// mount it decrypts and returns the DSN (today's path, byte-for-byte). For a
// cred-ref mount (S2) it returns the credential_ref so the data plane resolves
// the real DSN itself via its CredentialProvider registry — no plaintext DSN
// ever travels back through the control plane for a Vault-backed mount.
func (s *Service) GetConnection(ctx context.Context, userID, id string) (ConnectionResult, error) {
	var (
		engine     string
		isolation  string
		payload    EncryptedPayload
		provider   *string
		reference  *string
		version    *string
		cmekWrap   []byte
		cmekKeyPtr *string
	)
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		// EXPLICIT tenant scope (not just the RLS policy): the control-plane DB
		// role owns/bypasses RLS on tenant_databases, so without `AND
		// tenant_id = $2` a mount's UUID would be a bearer capability — ANY
		// valid tenant key + the dbId would resolve (and read) ANOTHER
		// tenant's mount. The whole tenant_owned safety model rests on this
		// caller==owner check at resolve time. `userID` is the caller tenant
		// the query-router forwards as X-Tenant-Id.
		row := tx.QueryRow(ctx,
			`SELECT engine, isolation, connection_enc, connection_iv, connection_tag, connection_salt,
			        cred_provider, cred_reference, cred_version,
			        cmek_wrapped_dek, cmek_kms_key_id
			   FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2`, id, userID)
		err := row.Scan(&engine, &isolation, &payload.Encrypted, &payload.IV, &payload.Tag, &payload.Salt,
			&provider, &reference, &version,
			&cmekWrap, &cmekKeyPtr)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		// fire-and-forget health timestamp, same intent as the Node service
		_, _ = tx.Exec(ctx, `UPDATE public.tenant_databases SET last_healthy_at = now() WHERE id = $1 AND tenant_id = $2`, id, userID)
		return nil
	})
	if err != nil {
		return ConnectionResult{}, err
	}

	// Cred-ref mount: surface provider+reference (NO decrypt — there is no
	// ciphertext). The DB XOR check guarantees an inline row never reaches here
	// with cred_* set, so a populated cred_provider is unambiguously a ref mount.
	if provider != nil && *provider != "" {
		result := ConnectionResult{
			Engine:    engine,
			Isolation: isolation,
			CredentialRef: &CredentialRefInput{
				Provider:  *provider,
				Reference: derefStr(reference),
				Version:   derefStr(version),
			},
		}
		if name, pkg, ok := s.packageForTenant(ctx, userID); ok {
			result.Package = name
			result.CapabilityOverrides = pkg.CapabilityOverrides()
		}
		return result, nil
	}

	// CMEK / BYOK (D4.8): a cmek-envelope mount (cmek_wrapped_dek IS NOT NULL)
	// decrypts via the EXTERNAL KMS — unwrap the DEK, then AES-GCM-open the DSN.
	// It integrates with the SAME tag-cache + singleflight as the inline path, so
	// the KMS is hit ONCE per ciphertext (NOT per request). If CMEK is disabled or
	// no provider is wired, a stored cmek row cannot be served — fail closed
	// rather than silently treat the DEK-ciphertext as a master-key ciphertext.
	// If the KMS cannot unwrap (key revoked/deleted), cmek.Open returns
	// ErrShredded and the caller gets a non-2xx — crypto-shred by construction.
	usingCMEK := len(cmekWrap) > 0
	if usingCMEK && (!s.cmekEnabled || s.kms == nil) {
		return ConnectionResult{}, errors.New("cmek mount stored but CMEK is disabled/unconfigured — cannot decrypt")
	}

	// decrypt only when the ciphertext changed since the last call (the auth tag
	// is a cryptographic digest of payload+key — equal tag ⇒ equal plaintext).
	// Concurrent misses for one mount coalesce (sf); distinct cold inline mounts
	// queue on the Encryptor's scryptSlots. See connCache.
	var conn string
	tag := string(payload.Tag)
	if v, ok := s.connCache.Load(id); ok {
		if e, ok := v.(connCacheEntry); ok && e.tag == tag {
			conn = e.conn
		}
	}
	if conn == "" {
		v, derr, _ := s.sf.Do(id+"\x00"+tag, func() (any, error) {
			if v, ok := s.connCache.Load(id); ok {
				if e, ok := v.(connCacheEntry); ok && e.tag == tag {
					return e.conn, nil
				}
			}
			var (
				c   string
				err error
			)
			if usingCMEK {
				// Unwrap the DEK via the KMS using the row's stored key id, then
				// AES-GCM-open the DEK-encrypted DSN (enc||tag reassembled).
				ct := cmek.JoinCiphertext(payload.Encrypted, payload.Tag)
				plain, oErr := cmek.Open(ctx, s.kms, derefStr(cmekKeyPtr), cmekWrap, payload.IV, ct)
				if oErr != nil {
					return nil, oErr
				}
				c = string(plain)
			} else {
				c, err = s.enc.Decrypt(payload)
				if err != nil {
					return nil, err
				}
			}
			s.connCache.Store(id, connCacheEntry{tag: tag, conn: c})
			return c, nil
		})
		if derr != nil {
			return ConnectionResult{}, derr
		}
		conn, _ = v.(string)
	}
	result := ConnectionResult{Engine: engine, ConnectionString: conn, Isolation: isolation}
	// Phase 4 tiering: stamp the tenant's package tier mask so the data plane
	// enforces capability gating (403) + rate limiting (429). Resolved from the
	// tenant's `plan`; a no-op when PACKAGE_ENFORCEMENT=0.
	if name, pkg, ok := s.packageForTenant(ctx, userID); ok {
		result.Package = name
		result.CapabilityOverrides = pkg.CapabilityOverrides()
	}
	return result, nil
}

// Remove deletes a database by id (admin scope, bypasses RLS).
func (s *Service) Remove(ctx context.Context, id string) error {
	rows, err := s.db.AdminQuery(ctx,
		`DELETE FROM public.tenant_databases WHERE id = $1 RETURNING id`, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return ErrNotFound
	}
	return nil
}

// RemoveScoped deletes a mount by id, CALLER-SCOPED — the SQL binds BOTH the id
// AND the caller's tenant_id, so a mount UUID is NEVER a bearer capability: a
// caller can only ever delete its OWN mount, even if it guessed another tenant's
// uuid. This is the self-serve builder's delete (DELETE /databases/{id}/self),
// distinct from the admin Remove (DELETE /databases/{id}) which bypasses RLS for
// operator teardown. `userID` is the caller tenant the query-router forwards as
// X-Baas-Tenant-Id (the same scope GetConnection/List use). The connCache entry
// for the id is invalidated so a stale decrypted DSN cannot survive the delete.
func (s *Service) RemoveScoped(ctx context.Context, userID, id string) error {
	rows, err := s.db.AdminQuery(ctx,
		`DELETE FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2 RETURNING id`, id, userID)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return ErrNotFound
	}
	s.connCache.Delete(id)
	return nil
}
