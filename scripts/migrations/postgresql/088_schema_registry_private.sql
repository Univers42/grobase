-- Migration 088: public.schema_registry is not reachable with the public API key.
--
-- 001_initial_schema and db-bootstrap grant anon + authenticated SELECT, INSERT,
-- UPDATE, DELETE on every table in `public` and rely on RLS to scope the rows.
-- schema_registry (the cross-tenant table catalog: database_id, table names,
-- column definitions, created_by) had no RLS, so the anon key could read, insert
-- and delete it through PostgREST (/rest/v1/schema_registry).
--
-- Its only user, schema-service, queries it over the admin (superuser) pool, so
-- the public roles lose every privilege and RLS is on + forced with no policy:
-- deny for any role that is neither superuser nor BYPASSRLS. Idempotent.
DO $$
BEGIN
  IF to_regclass('public.schema_registry') IS NULL THEN
    RETURN;
  END IF;
  REVOKE ALL ON public.schema_registry FROM anon, authenticated;
  ALTER TABLE public.schema_registry ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.schema_registry FORCE ROW LEVEL SECURITY;
END
$$;
