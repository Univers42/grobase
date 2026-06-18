-- File: scripts/migrations/postgresql/043_orgs.sql
-- Migration 043: Organizations / teams / members / invites (Track-D D1 — the
-- keystone control-plane layer BETWEEN a human and a project(=tenant)).
--
-- ADDITIVE ONLY. Creates the three new control-plane tables the flag-gated org
-- model (ORG_MODEL_ENABLED, default OFF) needs to add a multi-user layer ABOVE
-- tenants(=projects), plus ONE nullable FK column on public.tenants linking a
-- project to its parent org:
--
--   public.orgs         : the new root entity above tenants(=projects). An org
--                         is owned/operated by humans (GoTrue user uuids), has a
--                         slug + name + plan + status, and rolls down to projects.
--   public.org_members  : a human user's role within an org (owner|admin|developer|
--                         billing|viewer). UNIQUE(org_id,user_id) = one role per
--                         user per org. user_id is the GoTrue user uuid — the SAME
--                         id space as tenants.owner_user_id.
--   public.org_invites  : an outstanding email invitation. token_hash stores ONLY
--                         lower-hex sha256(cleartext_token); the cleartext is
--                         returned ONCE at issue time and emailed, NEVER persisted
--                         (same discipline as tenant_api_keys.key_hash). A high-
--                         entropy token → fast hash (SHA-256), per kernel rule #7.
--
-- THE LOAD-BEARING CONSTRAINT (D-026): org-scoping lives ENTIRELY in the control
-- plane. It NEVER enters RequestIdentity, the RLS GUCs (app.current_tenant_id /
-- app.current_user_id), or the data plane. Orgs sit ABOVE tenants; a tenant still
-- resolves + isolates EXACTLY as today. The ONE change to an existing object is an
-- ADD COLUMN IF NOT EXISTS tenants.org_id (nullable, default NULL) — additive,
-- back-compatible, read by NOTHING on the request path (the data plane never
-- selects it). So per-request isolation + SHARE_POOLS (24,887 tenants -> 1 pool)
-- stay byte-untouched.
--
-- Migration number 043 was RESERVED for exactly this slice by 045_tenant_safety.sql
-- ("043 org data model, 044 per-org billing rollup").
--
-- Running this migration changes NO existing behavior: with ORG_MODEL_ENABLED OFF
-- (the default) the /v1/orgs* routes are never mounted, so nothing ever writes
-- these tables (they stay empty) and tenants.org_id stays NULL for every row =
-- byte-parity baseline (the same story as 040 / 041 / 042 / 045). Mirrors the RLS
-- + grant pattern of those migrations; the org RLS keys on auth.current_user_id()
-- (a USER identity that already exists, 016_unify_rls.sql) through membership — it
-- introduces NO org concept into auth.current_tenant_id(), so the per-request
-- tenant isolation function is byte-unchanged.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 43) THEN
    RAISE NOTICE 'Migration 043 already applied - skipping';
    RETURN;
  END IF;

  -- ── orgs: the new root entity above tenants(=projects) ──────────────────────
  CREATE TABLE IF NOT EXISTS public.orgs (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug          TEXT        NOT NULL UNIQUE
                  CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,62}$'),   -- same charset as tenants.slug
    name          TEXT        NOT NULL,
    plan          TEXT        NOT NULL DEFAULT 'free',            -- org-level tier (rolls down to projects)
    status        TEXT        NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','suspended','deleted')),
    metadata      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_by    TEXT,                                           -- GoTrue user uuid of the creator
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- ── org_members: a human user's role within an org ──────────────────────────
  -- user_id is the GoTrue user uuid (the SAME id space as tenants.owner_user_id).
  -- role is the RBAC role. PRIMARY KEY(org_id,user_id) = one role per user per org.
  CREATE TABLE IF NOT EXISTS public.org_members (
    org_id        UUID        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    user_id       TEXT        NOT NULL,
    role          TEXT        NOT NULL DEFAULT 'viewer'
                  CHECK (role IN ('owner','admin','developer','billing','viewer')),
    invited_by    TEXT,                                           -- user_id of the inviter (audit)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (org_id, user_id)
  );
  CREATE INDEX IF NOT EXISTS org_members_user_idx ON public.org_members (user_id);

  -- ── org_invites: an outstanding email invitation, token sha256-hashed ───────
  -- token_hash stores ONLY lower-hex sha256(cleartext_token) — the cleartext is
  -- returned ONCE at issue time and emailed, NEVER persisted (same discipline as
  -- tenant_api_keys.key_hash). A high-entropy token → fast hash (SHA-256).
  CREATE TABLE IF NOT EXISTS public.org_invites (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id        UUID        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    email         TEXT        NOT NULL,
    role          TEXT        NOT NULL DEFAULT 'viewer'
                  CHECK (role IN ('owner','admin','developer','billing','viewer')),
    token_hash    TEXT        NOT NULL,                           -- lower-hex sha256(token); UNIQUE
    invited_by    TEXT        NOT NULL,                           -- user_id of the inviter
    status        TEXT        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','accepted','revoked','expired')),
    expires_at    TIMESTAMPTZ NOT NULL,
    accepted_by   TEXT,                                           -- user_id who accepted (audit)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    accepted_at   TIMESTAMPTZ
  );
  CREATE UNIQUE INDEX IF NOT EXISTS org_invites_token_hash_key ON public.org_invites (token_hash);
  CREATE INDEX IF NOT EXISTS org_invites_org_pending_idx
    ON public.org_invites (org_id) WHERE status = 'pending';
  -- prevent two live invites for the same (org,email): partial unique on pending.
  CREATE UNIQUE INDEX IF NOT EXISTS org_invites_org_email_pending_key
    ON public.org_invites (org_id, lower(email)) WHERE status = 'pending';

  -- ── the ONE existing-object change: link tenants(=projects) to an org ────────
  -- Nullable, default NULL → every existing tenant stays org-less = today's shape.
  -- Read by NO request-path code (the data plane never selects it). ON DELETE SET
  -- NULL so deleting an org orphans projects to org-less rather than destroying data.
  ALTER TABLE public.tenants
    ADD COLUMN IF NOT EXISTS org_id UUID REFERENCES public.orgs(id) ON DELETE SET NULL;
  CREATE INDEX IF NOT EXISTS tenants_org_idx ON public.tenants (org_id) WHERE org_id IS NOT NULL;

  -- House RLS pattern (mirrors 040–045): orgs are NOT tenant_id-keyed, so the
  -- policy keys on the caller's user_id (auth.current_user_id(), already defined +
  -- granted in 016_unify_rls.sql) scoped through membership. The control-plane
  -- service runs as the BYPASSRLS service_role, so its writes are unaffected; the
  -- RLS is the second wall behind the Go capability check for any tenant-facing
  -- direct read. It introduces NO org concept into auth.current_tenant_id().
  ALTER TABLE public.orgs        ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.org_members ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.org_invites ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='orgs' AND policyname='orgs_member_visibility'
    ) THEN
      CREATE POLICY orgs_member_visibility ON public.orgs FOR SELECT USING (
        EXISTS (SELECT 1 FROM public.org_members m
                 WHERE m.org_id = orgs.id AND m.user_id = auth.current_user_id()::text));
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='org_members' AND policyname='org_members_self_org'
    ) THEN
      CREATE POLICY org_members_self_org ON public.org_members FOR SELECT USING (
        EXISTS (SELECT 1 FROM public.org_members m2
                 WHERE m2.org_id = org_members.org_id AND m2.user_id = auth.current_user_id()::text));
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='org_invites' AND policyname='org_invites_self_org'
    ) THEN
      CREATE POLICY org_invites_self_org ON public.org_invites FOR SELECT USING (
        EXISTS (SELECT 1 FROM public.org_members m
                 WHERE m.org_id = org_invites.org_id AND m.user_id = auth.current_user_id()::text));
    END IF;
  END $pol$;

  GRANT SELECT, INSERT, UPDATE, DELETE ON public.orgs        TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.org_members TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.org_invites TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (43, '043_orgs')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- ALTER TABLE public.tenants DROP COLUMN IF EXISTS org_id;
-- DROP TABLE IF EXISTS public.org_invites;
-- DROP TABLE IF EXISTS public.org_members;
-- DROP TABLE IF EXISTS public.orgs;
-- DELETE FROM public.schema_migrations WHERE version = 43;
-- COMMIT;
