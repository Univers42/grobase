-- Migration 093: anon and authenticated hold nothing on public.engine_schema_migrations.
--
-- schema-service creates this table from TypeScript at boot (schemas.module.ts onModuleInit,
-- adminQuery) rather than from a migration, so it predates 089: it was created while the
-- default privilege still handed SELECT/INSERT/UPDATE/DELETE on every new public table to
-- anon and authenticated. 089 revoked that default going forward but never revisited the
-- tables already created, so this one kept the stale grants with no RLS to scope it —
-- the public anon key could read and rewrite the schema-engine migration bookkeeping over
-- /rest/v1. m200 step 1/7 is the gate that names it.
--
-- Nothing reaches this table as anon: schema-service writes it through adminQuery, and
-- service_role keeps its privileges. Idempotent; a no-op where the table does not exist.
--
-- DOWN (manual, re-opens the write): GRANT SELECT, INSERT, UPDATE, DELETE ON
-- public.engine_schema_migrations TO anon, authenticated;
DO $$
BEGIN
  IF to_regclass('public.engine_schema_migrations') IS NOT NULL THEN
    REVOKE ALL ON public.engine_schema_migrations FROM anon, authenticated;
  END IF;
END $$;

INSERT INTO public.schema_migrations (version, name)
SELECT 93, '093_engine_schema_migrations_grants'
WHERE NOT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 93);