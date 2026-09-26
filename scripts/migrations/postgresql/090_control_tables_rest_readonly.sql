-- Migration 090: control-plane tables are not reachable over REST or GraphQL (N-36).
--
-- For a GoTrue user token auth.current_tenant_id() falls back to the user's own uuid, so
-- every policy keyed on it let any signed-up user INSERT a tenants row with id = their
-- uuid (any plan, any owner_user_id) through /rest/v1 or /graphql/v1, then write every
-- tenant-keyed control row for it (sso_connections, scim_tokens, entitlements, billing).
-- A legitimate tenant id is never a user's uuid (033 and tenant-control let the default
-- pick it), so for a REST caller these policies match only forged rows: the tables are
-- read and written by the control and data planes, which connect as the database owner.
-- anon and authenticated therefore lose EVERY privilege on:
--   * each relation with a write policy that calls current_tenant_id() (auth or public),
--     and its partitions/children, found through pg_depend rather than by name, so a new
--     tenant-keyed table is covered without editing this file;
--   * vault42_secrets/_audit/_grants (071 revoked them; the pre-089 bootstrap re-granted);
--   * org_usage_rollup, a view that ran as its owner and so bypassed RLS: any signed-up
--     user read every org's usage. It is security_invoker from now on as well.
-- audit_log keeps its self-read and loses writes (its insert policy is WITH CHECK (true)).
-- TRUNCATE, REFERENCES and TRIGGER leave every public relation: RLS never governs TRUNCATE.
-- 003/004/005/030 no longer grant their control tables on each boot; the guarded
-- migrations grant only on a fresh install, in the same run that reaches this file.
-- Revoking does not undo rows forged before this ran: scripts/security/detect-forged-tenants.sql.
-- Ponytail: the pg_depend rule misses a tenant-keyed policy that goes through a wrapper
-- function or reads current_setting('app.current_tenant_id') itself. m200 pins today's
-- tables and allowlists the REST-writable ones, so either shape fails the gate instead.
-- Idempotent; re-runs on every boot.
--
-- DOWN (manual, re-opens N-36): GRANT SELECT, INSERT, UPDATE, DELETE ON public.<table> TO authenticated;
DO $$
DECLARE
  t regclass;
BEGIN
  FOR t IN
    WITH RECURSIVE keyed AS (
      SELECT DISTINCT pol.polrelid AS rel
        FROM pg_policy pol
        JOIN pg_depend d ON d.classid = 'pg_policy'::regclass AND d.objid = pol.oid
                        AND d.refclassid = 'pg_proc'::regclass
        JOIN pg_proc f ON f.oid = d.refobjid AND f.proname = 'current_tenant_id'
        JOIN pg_namespace fn ON fn.oid = f.pronamespace AND fn.nspname IN ('auth', 'public')
       WHERE pol.polcmd IN ('*', 'a', 'w', 'd')
      UNION
      SELECT i.inhrelid FROM pg_inherits i JOIN keyed k ON i.inhparent = k.rel
    )
    SELECT k.rel::regclass FROM keyed k JOIN pg_class c ON c.oid = k.rel
     WHERE c.relnamespace = 'public'::regnamespace
    UNION
    SELECT to_regclass(n) FROM unnest(ARRAY['public.vault42_secrets', 'public.vault42_audit',
                                            'public.vault42_grants', 'public.org_usage_rollup']) n
     WHERE to_regclass(n) IS NOT NULL
  LOOP
    EXECUTE format('REVOKE ALL ON %s FROM anon, authenticated', t);
  END LOOP;

  IF to_regclass('public.org_usage_rollup') IS NOT NULL THEN
    ALTER VIEW public.org_usage_rollup SET (security_invoker = true);
  END IF;
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.audit_log FROM anon, authenticated;
  END IF;

  FOR t IN
    SELECT c.oid::regclass FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  LOOP
    EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER ON %s FROM anon, authenticated', t);
  END LOOP;
END
$$;

-- Record it (the body above re-runs on every boot; this keeps migrate-status honest).
INSERT INTO public.schema_migrations (version, name)
SELECT 90, '090_control_tables_rest_readonly'
WHERE NOT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 90);
