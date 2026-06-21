-- 077_environments.sql — per-project environments (dev/staging/prod): the key-bearing scope.
--
-- Additive + idempotent. CONTROL-PLANE ONLY: like orgs (043) and teams (072) this table never
-- enters RequestIdentity, the RLS GUCs (app.current_tenant_id / app.current_user_id), or the
-- data plane. An environment scopes secrets+grants within a project(=tenant); vault42 derives a
-- per-environment keypair (scope_id = BLAKE3(project_uuid || env_name)) from it. Mirrors the 072
-- RLS pattern (ENABLE + a member-visibility SELECT policy keyed on auth.current_user_id();
-- writes go through the admin BYPASSRLS pool).
--
-- FLAG-GATED OFF = PARITY: main mounts /v1/projects/{id}/environments* ONLY when
-- ENVIRONMENTS_ENABLED is truthy (which itself requires RBAC_HIERARCHY_ENABLED). OFF (default)
-- ⇒ no routes, no rows written here.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 77) THEN
    RAISE NOTICE 'Migration 077 already applied - skipping';
    RETURN;
  END IF;

  -- An environment is a named slice of a project; secrets+grants may scope to one.
  CREATE TABLE IF NOT EXISTS public.environments (
    id         uuid        NOT NULL DEFAULT gen_random_uuid(),
    project_id uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    name       text        NOT NULL CHECK (name ~ '^[a-z0-9][a-z0-9_-]{0,62}$'),
    created_by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (project_id, name)
  );
  CREATE INDEX IF NOT EXISTS environments_project ON public.environments (project_id);

  ALTER TABLE public.environments ENABLE ROW LEVEL SECURITY;
  -- a user sees an environment iff they own the project or belong to the project's org.
  DROP POLICY IF EXISTS environments_member_visibility ON public.environments;
  CREATE POLICY environments_member_visibility ON public.environments FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.tenants t
              WHERE t.id = environments.project_id
                AND (t.owner_user_id = auth.current_user_id()::text
                  OR EXISTS (SELECT 1 FROM public.org_members m
                               WHERE m.org_id = t.org_id
                                 AND m.user_id = auth.current_user_id()::text))));
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.environments TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (77, '077_environments') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
