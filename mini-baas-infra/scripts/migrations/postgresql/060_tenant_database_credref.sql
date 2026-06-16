-- File: scripts/migrations/postgresql/060_tenant_database_credref.sql
-- Migration 060: G-Vault (S2) — let a tenant register an external DB mount as a
-- Vault credential REFERENCE instead of an inline plaintext (encrypted-at-rest)
-- DSN, and let SECURITY_MODE=max tenants FORBID the inline path entirely.
--
-- ADDITIVE + REVERSIBLE-IN-INTENT. Adds three NULLABLE columns to
-- public.tenant_databases and makes the four inline-encrypted columns nullable,
-- then a CHECK enforcing EXACTLY ONE of {inline-encrypted, cred-ref} per row:
--
--   cred_provider   TEXT  -- the data-plane CredentialProvider name (e.g. 'vault')
--   cred_reference  TEXT  -- the provider-scoped secret reference (e.g. KV v2 path)
--   cred_version    TEXT  -- optional version pin (rotation keys a distinct pool)
--
-- An INLINE row keeps connection_enc/iv/tag (and the optional salt) populated and
-- leaves all three cred_* NULL — byte-identical to every pre-060 row, so the live
-- baseline is untouched. A CRED-REF row leaves connection_enc/iv/tag NULL and
-- populates cred_provider + cred_reference (cred_version optional); the data plane
-- resolves the real DSN at query time via the Rust VaultProvider (credential.rs),
-- so no secret is ever encrypted-at-rest in this table for a ref-backed mount.
--
-- Migration number 060 is deliberately RESERVED above the Track-D 04x/05x climb
-- (043 orgs … 049 ip-allowlist, with 05x reserved for that session) so this
-- G-Vault slice never collides with the concurrent org/audit work.
--
-- Idempotent: every column add is IF NOT EXISTS; the CHECK is dropped-then-added
-- by a stable name; the NOT NULL drops are unconditional ALTERs (no-op when
-- already nullable). Re-running converges. With no tenant ever registering a
-- cred-ref mount, this changes NOTHING on a request path = byte-parity baseline
-- (the same story as 040–049). Mirrors the guarded-DO + schema_migrations footer
-- of the recent migrations.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 60) THEN
    RAISE NOTICE 'Migration 060 already applied - skipping';
    RETURN;
  END IF;

  -- ── 1) cred-ref columns (all NULLABLE; absent = inline = today's row) ────────
  -- cred_provider names a data-plane CredentialProvider (credential.rs registry,
  -- e.g. 'vault'); cred_reference is the provider-scoped secret reference; the
  -- optional cred_version pins a version (a bump forks a fresh pool downstream).
  ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_provider  TEXT;
  ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_reference TEXT;
  ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_version   TEXT;

  -- ── 2) make the inline-encrypted columns NULLABLE ───────────────────────────
  -- A cred-ref row stores NO encrypted DSN, so the historically-NOT NULL inline
  -- columns must allow NULL. Existing INLINE rows are unaffected (they keep their
  -- non-null values); the CHECK below is what now guarantees an inline row still
  -- carries all three. DROP NOT NULL is a no-op when a column is already nullable
  -- (connection_salt has been nullable since 006), so this stays idempotent.
  ALTER TABLE public.tenant_databases ALTER COLUMN connection_enc  DROP NOT NULL;
  ALTER TABLE public.tenant_databases ALTER COLUMN connection_iv   DROP NOT NULL;
  ALTER TABLE public.tenant_databases ALTER COLUMN connection_tag  DROP NOT NULL;

  -- ── 3) CHECK: EXACTLY ONE of {inline-encrypted, cred-ref} per row ───────────
  -- inline_complete : the three inline-encrypted columns are all present (salt is
  --                   optional — pre-006 rows lacked it) AND no cred_* set.
  -- credref_complete: cred_provider + cred_reference present (cred_version
  --                   optional) AND no inline-encrypted column set.
  -- Drop-by-name first so re-running re-installs cleanly (idempotent). The CHECK
  -- only bites NEW inserts/updates; every pre-060 row is inline_complete already.
  ALTER TABLE public.tenant_databases
    DROP CONSTRAINT IF EXISTS tenant_databases_credential_xor_check;
  ALTER TABLE public.tenant_databases
    ADD CONSTRAINT tenant_databases_credential_xor_check CHECK (
      (
        connection_enc IS NOT NULL AND connection_iv IS NOT NULL
          AND connection_tag IS NOT NULL
          AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL
      )
      OR
      (
        cred_provider IS NOT NULL AND cred_reference IS NOT NULL
          AND connection_enc IS NULL AND connection_iv IS NULL
          AND connection_tag IS NULL AND connection_salt IS NULL
      )
    );

  INSERT INTO public.schema_migrations (version, name)
  VALUES (60, '060_tenant_database_credref')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_credential_xor_check;
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS cred_provider;
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS cred_reference;
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS cred_version;
-- -- (re-adding NOT NULL requires every row to carry the inline columns again)
-- DELETE FROM public.schema_migrations WHERE version = 60;
-- COMMIT;
