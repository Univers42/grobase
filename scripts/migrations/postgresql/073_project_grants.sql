-- 073_project_grants.sql — Track-D RBAC hierarchy: project-role grants + scoped tokens.
--
-- Additive + idempotent. CONTROL-PLANE ONLY (never enters the RLS GUCs / data plane).
--
-- project_grants is the EFFECTIVE-permission substrate: one unified table for both
-- User→Project and Team→Project grants, so the resolver is a single query whose MAX
-- is taken in Go (NEVER ORDER BY project_role — owner|admin|writer|reader do not sort
-- by privilege lexically). Three INDEPENDENT, AND-composed expiry gates guard a grant:
-- (1) project_grants.expires_at (the cheap short-circuit, here); (2) the ABAC
-- time_window condition (063, evaluated by has_permission for DATA ops — untouched);
-- (3) the rbac_token's own expires_at. `source` lets GitHub sync upsert idempotently
-- while a `manual` grant always wins.
--
-- rbac_tokens are short-lived, revocable, NON-ESCALATING scoped tokens (the role can
-- never exceed the issuer's effective role — enforced in Go, token_bound.go). The
-- `rbt_` prefix + a distinct table keep them disjoint from tenant API keys (`mbk_`).
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 73) THEN
    RAISE NOTICE 'Migration 073 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.project_grants (
    id           uuid        NOT NULL DEFAULT gen_random_uuid(),
    project_id   uuid        NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    org_id       uuid        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    grantee_kind text        NOT NULL CHECK (grantee_kind IN ('user','team')),
    grantee_id   text        NOT NULL,
    project_role text        NOT NULL CHECK (project_role IN ('owner','admin','writer','reader')),
    granted_by   text        NOT NULL,
    granted_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NULL,
    revoked_at   timestamptz NULL,
    source       text        NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','github_sync')),
    PRIMARY KEY (id)
  );
  -- one LIVE grant per (project, grantee) ⇒ a re-grant UPDATEs the role (idempotent upsert).
  CREATE UNIQUE INDEX IF NOT EXISTS project_grants_unique
    ON public.project_grants (project_id, grantee_kind, grantee_id) WHERE revoked_at IS NULL;
  CREATE INDEX IF NOT EXISTS project_grants_lookup
    ON public.project_grants (grantee_kind, grantee_id, project_id) WHERE revoked_at IS NULL;

  CREATE TABLE IF NOT EXISTS public.rbac_tokens (
    id             uuid        NOT NULL DEFAULT gen_random_uuid(),
    token_hash     text        NOT NULL UNIQUE,
    token_prefix   text        NOT NULL,
    issuer_user_id text        NOT NULL,
    scope_kind     text        NOT NULL CHECK (scope_kind IN ('org','project')),
    scope_id       text        NOT NULL,
    org_id         uuid        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    project_role   text        NOT NULL CHECK (project_role IN ('owner','admin','writer','reader')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    revoked_at     timestamptz NULL,
    PRIMARY KEY (id)
  );
  CREATE INDEX IF NOT EXISTS rbac_tokens_org ON public.rbac_tokens (org_id);

  ALTER TABLE public.project_grants ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.rbac_tokens    ENABLE ROW LEVEL SECURITY;
  -- org members may see their org's grants/tokens (mirrors orgs_member_visibility);
  -- writes go through the admin BYPASSRLS pool.
  DROP POLICY IF EXISTS project_grants_org_visibility ON public.project_grants;
  CREATE POLICY project_grants_org_visibility ON public.project_grants FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.org_members m
              WHERE m.org_id = project_grants.org_id AND m.user_id = auth.current_user_id()::text));
  DROP POLICY IF EXISTS rbac_tokens_org_visibility ON public.rbac_tokens;
  CREATE POLICY rbac_tokens_org_visibility ON public.rbac_tokens FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.org_members m
              WHERE m.org_id = rbac_tokens.org_id AND m.user_id = auth.current_user_id()::text));
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.project_grants TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.rbac_tokens    TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (73, '073_project_grants') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
