-- m264-prep.sql — the least of 001 and 016 that migrations 013, 015 and 022 and the boot DDL
-- of gdpr-service and session-service (RLS on auth.current_user_id()) lean on, so m264's
-- scratch Postgres runs the nine without db-bootstrap or GoTrue.
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version    INTEGER PRIMARY KEY,
  name       TEXT NOT NULL,
  applied_at TIMESTAMPTZ DEFAULT now()
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS auth;
-- Same body as 016_unify_rls.sql:21-27.
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'sub',
    NULLIF(current_setting('app.current_user_id', true), '')
  )::uuid;
$$;
