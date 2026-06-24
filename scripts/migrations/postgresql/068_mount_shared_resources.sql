-- File: scripts/migrations/postgresql/068_mount_shared_resources.sql
-- Migration 068: per-mount "shared resources" — let a registered DB mount declare
-- a list of table names that are NOT owner-scoped (a shared catalog readable
-- across owners). The Rust data plane already reads this list from a mount's
-- capability_overrides JSON under the reserved key `shared_resources`
-- (DatabaseMount::shared_resources, mount.rs); this migration lets the Go control
-- plane CARRY it from registration through GetConnection.
--
-- ADDITIVE + REVERSIBLE-IN-INTENT. One NULLABLE JSONB column:
--   shared_resources JSONB  -- array of plain table-name strings, or NULL/absent
--
-- ABSENT (NULL) = no shared tables = every table owner-scoped = byte-identical to
-- every pre-068 row, so the live baseline is untouched. With no mount ever
-- declaring shared_resources, this changes NOTHING on a request path = parity
-- (the same story as 040–065). 066/067 are the movieverse demo schema, so the
-- next free control-plane migration number is 068.
--
-- Idempotent: the column add is IF NOT EXISTS; re-running converges. Mirrors the
-- guarded-DO + schema_migrations footer of the recent migrations.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 68) THEN
    RAISE NOTICE 'Migration 068 already applied - skipping';
    RETURN;
  END IF;

  -- A JSONB array of plain table-name strings carried into the mount's
  -- capability_overrides.shared_resources by GetConnection. NULL/absent on every
  -- existing row ⇒ no opt-in ⇒ byte-parity (every table owner-scoped).
  ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS shared_resources JSONB;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (68, '068_mount_shared_resources')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS shared_resources;
-- DELETE FROM public.schema_migrations WHERE version = 68;
-- COMMIT;
