-- Migration 089: no default privilege for anon/authenticated on new public tables.
--
-- 001_initial_schema (and db-bootstrap) granted SELECT/INSERT/UPDATE/DELETE to anon and
-- authenticated on every FUTURE table in public. A table nothing granted explicitly —
-- one created through the DDL API on a mount pointing at this database, a gate's probe
-- table, a migration that forgot a GRANT — was therefore readable and writable with the
-- public anon key through PostgREST (N-3). Reachability is now opt-in per table, which
-- every REST-served table already declares. Idempotent; a no-op where the default was
-- never granted (per-app databases). db-bootstrap repeats it on every boot for installs
-- that no longer run migrations (fly).
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;

-- Record it (the body above re-runs on every boot; this keeps migrate-status honest).
INSERT INTO public.schema_migrations (version, name)
SELECT 89, '089_default_privileges_revoke'
WHERE NOT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 89);
