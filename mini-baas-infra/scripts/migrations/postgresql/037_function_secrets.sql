-- File: scripts/migrations/postgresql/037_function_secrets.sql
-- Migration 037: per-function secret store (A2 Functions DX).
--
-- A function_secret is an encrypted, tenant-scoped key/value. Values are sealed
-- with AES-256-GCM (scrypt-derived per-record key) reusing the EXACT crypto
-- layout of the adapter-registry CryptoService (4 columns: encrypted/iv/tag/
-- salt) so the same Go Encryptor decrypts both. The functions-runtime injects
-- whitelisted secrets into the Deno worker's env at invoke time
-- (--allow-env=<keys>).
--
-- Mirrors the RLS + idempotency pattern of 031/035/036. Owned by the
-- webhook-dispatcher (which already holds the DB pool + VAULT_ENC_KEY); rows are
-- tenant-scoped via RLS. Plaintext is NEVER returned by list/get.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 37) THEN
    RAISE NOTICE 'Migration 037 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.function_secrets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT NOT NULL,
    -- Scope: NULL/empty function_name = tenant-wide secret available to all the
    -- tenant's functions; a specific name scopes it to one function. The
    -- runtime resolves function-specific secrets over tenant-wide on conflict.
    function_name   TEXT NOT NULL DEFAULT '',
    -- The env var name injected into the worker. Uppercase-ish identifier.
    key             TEXT NOT NULL CHECK (key ~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$'),
    -- AES-256-GCM sealed value (same column layout as adapter credentials).
    encrypted       BYTEA NOT NULL,
    iv              BYTEA NOT NULL,
    tag             BYTEA NOT NULL,
    salt            BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, function_name, key)
  );

  CREATE INDEX IF NOT EXISTS function_secrets_tenant_idx
    ON public.function_secrets (tenant_id, function_name);

  ALTER TABLE public.function_secrets ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'function_secrets'
         AND policyname = 'function_secrets_tenant_isolation'
    ) THEN
      CREATE POLICY function_secrets_tenant_isolation ON public.function_secrets
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  GRANT SELECT, INSERT, UPDATE, DELETE ON public.function_secrets TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (37, '037_function_secrets')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.function_secrets;
-- DELETE FROM public.schema_migrations WHERE version = 37;
-- COMMIT;
