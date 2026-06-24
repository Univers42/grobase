-- 079_project_grants_ext.sql — extend 073 project_grants for groups, environments, standalone.
--
-- Additive + behaviour-preserving for existing rows (env_id NULL, org_id kept). Widens:
--   * grantee_kind  +'group'   (a project-scoped group is a grantee, like a user/team)
--   * env_id        NEW, NULL  (NULL = project-wide / all environments; non-NULL = one env)
--   * org_id        NULLABLE   (a standalone project has no org)
--   * source        +'invite'  (accept-time grants are auditable apart from manual/github_sync)
-- The effective-permission resolver (internal/teams/effective.go) still takes the MAX in Go;
-- more rows feed the same MAX. CONTROL-PLANE ONLY. FLAG-GATED by the same RBAC_HIERARCHY_ENABLED
-- (+ GROUPS_ENABLED for group grants, ENVIRONMENTS_ENABLED for env grants) — OFF ⇒ unused.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 79) THEN
    RAISE NOTICE 'Migration 079 already applied - skipping';
    RETURN;
  END IF;

  ALTER TABLE public.project_grants
    ADD COLUMN IF NOT EXISTS env_id uuid NULL REFERENCES public.environments(id) ON DELETE CASCADE;
  ALTER TABLE public.project_grants ALTER COLUMN org_id DROP NOT NULL;

  -- widen the inline CHECK constraints (Postgres names inline column checks <table>_<col>_check).
  ALTER TABLE public.project_grants DROP CONSTRAINT IF EXISTS project_grants_grantee_kind_check;
  ALTER TABLE public.project_grants
    ADD CONSTRAINT project_grants_grantee_kind_check
    CHECK (grantee_kind IN ('user','team','group'));
  ALTER TABLE public.project_grants DROP CONSTRAINT IF EXISTS project_grants_source_check;
  ALTER TABLE public.project_grants
    ADD CONSTRAINT project_grants_source_check
    CHECK (source IN ('manual','github_sync','invite'));

  -- one LIVE grant per (project, grantee, env) — env-aware. NULL env (project-wide) collapses to a
  -- fixed sentinel so two project-wide grants to the same grantee can't both be live (NULL!=NULL).
  DROP INDEX IF EXISTS project_grants_unique;
  CREATE UNIQUE INDEX IF NOT EXISTS project_grants_unique
    ON public.project_grants
       (project_id, grantee_kind, grantee_id,
        COALESCE(env_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE revoked_at IS NULL;

  -- visibility now also covers standalone (org_id NULL) grants via project ownership.
  DROP POLICY IF EXISTS project_grants_org_visibility ON public.project_grants;
  CREATE POLICY project_grants_org_visibility ON public.project_grants FOR SELECT USING (
    (project_grants.org_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.org_members m
          WHERE m.org_id = project_grants.org_id
            AND m.user_id = auth.current_user_id()::text))
    OR EXISTS (SELECT 1 FROM public.tenants t
                 WHERE t.id = project_grants.project_id
                   AND t.owner_user_id = auth.current_user_id()::text));

  INSERT INTO public.schema_migrations (version, name)
  VALUES (79, '079_project_grants_ext') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
