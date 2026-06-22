-- 078_groups.sql — project-scoped groups (always "<project>'s group"), distinct from teams.
--
-- A team (072) is org-scoped and spans projects; a GROUP's scope is its ONE project. Exactly one
-- group per project. Additive + idempotent, CONTROL-PLANE ONLY (never enters RLS GUCs / data
-- plane). Mirrors the 072 team_members RLS pattern, with an extra branch for the standalone
-- (org-less project) case keyed directly on group_members.user_id.
--
-- FLAG-GATED OFF = PARITY: main mounts /v1/projects/{id}/groups* + /v1/groups/* ONLY when
-- GROUPS_ENABLED is truthy (requires RBAC_HIERARCHY_ENABLED). OFF (default) ⇒ no routes, no rows.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 78) THEN
    RAISE NOTICE 'Migration 078 already applied - skipping';
    RETURN;
  END IF;

  -- A group groups users within one project; granting the group a project role propagates to members.
  -- org_id is denormalized (NULL for a standalone project) for RLS + listing.
  CREATE TABLE IF NOT EXISTS public.groups (
    id         uuid        NOT NULL DEFAULT gen_random_uuid(),
    project_id uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    org_id     uuid        NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    name       text        NOT NULL CHECK (name LIKE '%''s group'),
    created_by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id)
  );
  -- exactly one group per project.
  CREATE UNIQUE INDEX IF NOT EXISTS groups_project_unique ON public.groups (project_id);
  CREATE INDEX IF NOT EXISTS groups_org ON public.groups (org_id) WHERE org_id IS NOT NULL;

  CREATE TABLE IF NOT EXISTS public.group_members (
    group_id   uuid        NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
    user_id    text        NOT NULL,
    added_by   text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, user_id)
  );
  CREATE INDEX IF NOT EXISTS group_members_user ON public.group_members (user_id);

  ALTER TABLE public.groups        ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.group_members ENABLE ROW LEVEL SECURITY;
  -- a user sees a group iff they own its project, belong to its org, or are a member of the group.
  DROP POLICY IF EXISTS groups_member_visibility ON public.groups;
  CREATE POLICY groups_member_visibility ON public.groups FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.tenants t
              WHERE t.id = groups.project_id
                AND (t.owner_user_id = auth.current_user_id()::text
                  OR EXISTS (SELECT 1 FROM public.org_members m
                               WHERE m.org_id = t.org_id
                                 AND m.user_id = auth.current_user_id()::text)))
    OR EXISTS (SELECT 1 FROM public.group_members gm
                 WHERE gm.group_id = groups.id
                   AND gm.user_id = auth.current_user_id()::text));
  DROP POLICY IF EXISTS group_members_self ON public.group_members;
  CREATE POLICY group_members_self ON public.group_members FOR SELECT USING (
    group_members.user_id = auth.current_user_id()::text
    OR EXISTS (SELECT 1 FROM public.groups g JOIN public.tenants t ON t.id = g.project_id
                 WHERE g.id = group_members.group_id
                   AND (t.owner_user_id = auth.current_user_id()::text
                     OR EXISTS (SELECT 1 FROM public.org_members m
                                  WHERE m.org_id = t.org_id
                                    AND m.user_id = auth.current_user_id()::text))));
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.groups        TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_members TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (78, '078_groups') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
