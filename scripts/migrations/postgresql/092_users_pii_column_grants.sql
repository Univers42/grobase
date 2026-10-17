-- Migration 092: anon and authenticated never read public.users.password_hash, and anon
-- never reads email (b2b incident 2026-10-17, groot ADR 0014).
--
-- On b2b anon read every user's email (public.movieverse_profiles, policy USING (true))
-- and anon/authenticated held SELECT on public.users.email and .password_hash. It was
-- contained by hand; this file makes the containment survive `make migrate`.
-- It must sort after 001_initial_schema.sql: `make migrate` and pg-migrate re-run EVERY
-- file on EVERY boot (50-migrate.mk), and 001:91,94 re-grants table-level SELECT on
-- public.users to anon and authenticated each time. A table-level grant also masks any
-- column-level REVOKE, so the only shape that holds is: revoke the table grant, then
-- grant columns. Nothing after this file may re-grant SELECT on public.users.
--
--   * movieverse_profiles (a vendor-app table, absent from a fresh install): anon and
--     authenticated lose every privilege; its reader, if any, goes through the service role.
--   * users, anon: SELECT on id, username, is_email_verified only (those that exist).
--   * users, authenticated: SELECT on every column but password_hash. email stays readable
--     because RLS (users_select_own) limits the rows to the caller's own.
-- INSERT/UPDATE/DELETE grants on users are untouched.
-- Caveat: `SELECT *` over /rest/v1/users fails for anon, and for authenticated wherever
-- password_hash exists: callers name their columns. Column lists are read at run time, so a
-- column added later is covered for authenticated only after the next migrate.
-- Idempotent; no-op where the tables do not exist.
--
-- DOWN (manual, re-opens the leak): GRANT SELECT ON public.users TO anon, authenticated;
DO $$
DECLARE
  anon_cols text;
  authenticated_cols text;
BEGIN
  IF to_regclass('public.movieverse_profiles') IS NOT NULL THEN
    REVOKE ALL ON public.movieverse_profiles FROM anon, authenticated;
  END IF;

  IF to_regclass('public.users') IS NULL THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) INTO anon_cols
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'users'
     AND column_name IN ('id', 'username', 'is_email_verified');
  SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) INTO authenticated_cols
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'users' AND column_name <> 'password_hash';

  REVOKE ALL ON public.users FROM anon;
  REVOKE SELECT ON public.users FROM authenticated;
  IF anon_cols IS NOT NULL THEN
    EXECUTE format('GRANT SELECT (%s) ON public.users TO anon', anon_cols);
  END IF;
  EXECUTE format('GRANT SELECT (%s) ON public.users TO authenticated', authenticated_cols);
END $$;

INSERT INTO public.schema_migrations (version, name)
SELECT 92, '092_users_pii_column_grants'
WHERE NOT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 92);
