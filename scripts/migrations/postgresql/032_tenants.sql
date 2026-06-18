-- File: scripts/migrations/postgresql/032_tenants.sql
-- Migration 032: extend the existing tenants registry + tenant_api_keys with
-- the fields the new tenant-control service needs.
--
-- Pre-existing shape (from migration 005):
--   tenants(id UUID PK, name, plan, created_at)  -- FK'd by apps + projects
--   tenant_api_keys(id, tenant_id UUID, name, key_hash, key_prefix, scopes, …)
--
-- This migration is ADDITIVE — it never drops/renames a column referenced by
-- another table. It adds:
--   tenants.slug             TEXT UNIQUE  -- human-readable id used everywhere
--   tenants.status           TEXT
--   tenants.owner_user_id    TEXT
--   tenants.metadata         JSONB
--   tenants.updated_at       TIMESTAMPTZ + trigger
--   tenant_api_keys.revoked_at  TIMESTAMPTZ + partial index
--   tenant_api_keys (tenant_id, name) UNIQUE
--
-- The slug is what the public API + signed envelopes use as `tenant_id`.
-- Existing rows get auto-assigned a slug derived from the UUID.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 32) THEN
    RAISE NOTICE 'Migration 032 already applied - skipping';
    RETURN;
  END IF;

  -- 1. tenants: additive columns.
  ALTER TABLE public.tenants
    ADD COLUMN IF NOT EXISTS slug          TEXT,
    ADD COLUMN IF NOT EXISTS status        TEXT NOT NULL DEFAULT 'active',
    ADD COLUMN IF NOT EXISTS owner_user_id TEXT,
    ADD COLUMN IF NOT EXISTS metadata      JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS updated_at    TIMESTAMPTZ NOT NULL DEFAULT now();

  -- Back-fill slug for any pre-existing rows.
  UPDATE public.tenants SET slug = 't-' || replace(id::text, '-', '') WHERE slug IS NULL;

  -- Enforce slug shape + uniqueness now that back-fill is done.
  ALTER TABLE public.tenants ALTER COLUMN slug SET NOT NULL;
  DO $cons$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint WHERE conname = 'tenants_slug_key'
    ) THEN
      ALTER TABLE public.tenants
        ADD CONSTRAINT tenants_slug_key UNIQUE (slug);
    END IF;
  END $cons$;

  DO $cons2$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint WHERE conname = 'tenants_slug_format'
    ) THEN
      ALTER TABLE public.tenants
        ADD CONSTRAINT tenants_slug_format CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,62}$');
    END IF;
  END $cons2$;

  DO $cons3$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint WHERE conname = 'tenants_status_check'
    ) THEN
      ALTER TABLE public.tenants
        ADD CONSTRAINT tenants_status_check CHECK (status IN ('active','suspended','deleted'));
    END IF;
  END $cons3$;

  CREATE INDEX IF NOT EXISTS tenants_owner_idx
    ON public.tenants(owner_user_id) WHERE owner_user_id IS NOT NULL;
  CREATE INDEX IF NOT EXISTS tenants_status_active_idx
    ON public.tenants(status) WHERE status <> 'deleted';

  -- updated_at trigger.
  CREATE OR REPLACE FUNCTION public._tenants_touch_updated_at()
  RETURNS trigger LANGUAGE plpgsql AS $fn$
  BEGIN
    NEW.updated_at := now();
    RETURN NEW;
  END;
  $fn$;

  DROP TRIGGER IF EXISTS tenants_updated_at ON public.tenants;
  CREATE TRIGGER tenants_updated_at
    BEFORE UPDATE ON public.tenants
    FOR EACH ROW EXECUTE FUNCTION public._tenants_touch_updated_at();

  -- 2. tenant_api_keys: additive.
  ALTER TABLE public.tenant_api_keys
    ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;

  DO $cons4$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint WHERE conname = 'tenant_api_keys_tenant_name_key'
    ) THEN
      -- partial unique: only enforce uniqueness for non-revoked keys so a
      -- revoked key can be re-created with the same name.
      CREATE UNIQUE INDEX tenant_api_keys_tenant_name_key
        ON public.tenant_api_keys (tenant_id, name)
        WHERE revoked_at IS NULL;
    END IF;
  END $cons4$;

  CREATE INDEX IF NOT EXISTS tenant_api_keys_prefix_lookup_idx
    ON public.tenant_api_keys (key_prefix)
    WHERE revoked_at IS NULL;

  GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenants TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_api_keys TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (32, '032_tenants')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated). The additive columns can be dropped:
-- BEGIN;
-- ALTER TABLE public.tenants
--   DROP COLUMN slug, DROP COLUMN status, DROP COLUMN owner_user_id,
--   DROP COLUMN metadata, DROP COLUMN updated_at;
-- ALTER TABLE public.tenant_api_keys DROP COLUMN revoked_at;
-- DROP FUNCTION public._tenants_touch_updated_at();
-- DELETE FROM public.schema_migrations WHERE version = 32;
-- COMMIT;
