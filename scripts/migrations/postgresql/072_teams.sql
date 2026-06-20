-- 072_teams.sql — Track-D RBAC hierarchy: teams + team membership.
--
-- Additive + idempotent. CONTROL-PLANE ONLY: like orgs (043) these tables never
-- enter RequestIdentity, the RLS GUCs (app.current_tenant_id / app.current_user_id),
-- or the data plane. Teams sit BELOW an org and ABOVE a project(=tenant); a tenant
-- still resolves + isolates exactly as today. Mirrors the 043 org-table RLS pattern
-- (ENABLE + a member-visibility SELECT policy keyed on auth.current_user_id();
-- writes go through the admin BYPASSRLS pool).
--
-- FLAG-GATED OFF = PARITY: main mounts the /v1/orgs/{id}/teams* routes ONLY when
-- RBAC_HIERARCHY_ENABLED is truthy. OFF (default) ⇒ no routes, no rows written here.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 72) THEN
    RAISE NOTICE 'Migration 072 already applied - skipping';
    RETURN;
  END IF;

  -- A team groups org members; granting a team a project role propagates to members.
  CREATE TABLE IF NOT EXISTS public.teams (
    id         uuid        NOT NULL DEFAULT gen_random_uuid(),
    org_id     uuid        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    slug       text        NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,62}$'),
    name       text        NOT NULL,
    metadata   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    UNIQUE (org_id, slug)
  );
  CREATE INDEX IF NOT EXISTS teams_org ON public.teams (org_id);

  -- (team, user) membership. team_role=manager may invite members into the team.
  CREATE TABLE IF NOT EXISTS public.team_members (
    team_id    uuid        NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
    user_id    text        NOT NULL,
    team_role  text        NOT NULL DEFAULT 'member' CHECK (team_role IN ('manager','member')),
    added_by   text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (team_id, user_id)
  );
  CREATE INDEX IF NOT EXISTS team_members_user ON public.team_members (user_id);

  ALTER TABLE public.teams        ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.team_members ENABLE ROW LEVEL SECURITY;
  -- a user sees a team iff they are a member of the team's org (mirrors orgs_member_visibility).
  DROP POLICY IF EXISTS teams_member_visibility ON public.teams;
  CREATE POLICY teams_member_visibility ON public.teams FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.org_members m
              WHERE m.org_id = teams.org_id AND m.user_id = auth.current_user_id()::text));
  DROP POLICY IF EXISTS team_members_self_org ON public.team_members;
  CREATE POLICY team_members_self_org ON public.team_members FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.teams t JOIN public.org_members m ON m.org_id = t.org_id
              WHERE t.id = team_members.team_id AND m.user_id = auth.current_user_id()::text));
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.teams        TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.team_members TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (72, '072_teams') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
