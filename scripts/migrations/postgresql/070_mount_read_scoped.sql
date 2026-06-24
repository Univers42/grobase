-- File: scripts/migrations/postgresql/070_mount_read_scoped.sql
-- Migration 070: per-mount "read_scoped" — let a registered DB mount turn ON
-- predicate-based READ owner-scoping for ITSELF, independent of the global env
-- DATA_PLANE_PG_READ_PREDICATE. The Rust data plane derives a pool's
-- read_predicate as `read_predicate_enabled() || mount.read_scoped()` — the
-- global flag OR this per-mount opt-in (DatabaseMount::read_scoped, mount.rs).
-- This migration lets the Go control plane CARRY the column from registration
-- through GetConnection (into capability_overrides, the same path 068 used for
-- shared_resources).
--
-- ADDITIVE + REVERSIBLE-IN-INTENT. One column:
--   read_scoped boolean NOT NULL DEFAULT false
--
-- DEFAULT false on every existing row ⇒ no per-mount opt-in ⇒ read_predicate is
-- decided by the global env flag alone = byte-identical to every pre-070 row, so
-- the live baseline is untouched (the same OFF=parity story as 040–068). 069 is
-- the dynamodb engine-check, so the next free control-plane migration number is
-- 070.
--
-- Idempotent: the column add is IF NOT EXISTS; re-running converges. Mirrors the
-- guarded-DO + schema_migrations footer of the recent migrations.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 70) THEN
    RAISE NOTICE 'Migration 070 already applied - skipping';
    RETURN;
  END IF;

  -- A boolean carried into the mount's capability_overrides.read_scoped by
  -- GetConnection. false on every existing row ⇒ no opt-in ⇒ read owner-scoping
  -- follows the global DATA_PLANE_PG_READ_PREDICATE flag alone (byte-parity).
  ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS read_scoped boolean NOT NULL DEFAULT false;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (70, '070_mount_read_scoped')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS read_scoped;
-- DELETE FROM public.schema_migrations WHERE version = 70;
-- COMMIT;
