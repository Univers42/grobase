-- File: scripts/migrations/postgresql/054_scim_tokens.sql
-- Migration 054: SCIM 2.0 provisioning bearer tokens + SCIM user mapping
-- (Track-D D2b — RFC 7644 cross-domain identity management).
--
-- ADDITIVE ONLY. Creates the two control-plane tables the flag-gated SCIM API
-- (SCIM_ENABLED, default OFF) needs, plus one additive column on the EXISTING
-- public.org_members so SCIM `active:false` can SOFT-deactivate a member without
-- removing the membership row (a hard remove is the DELETE path):
--
--   public.scim_tokens : an IdP's SCIM bearer credential. token_hash stores ONLY
--                        lower-hex sha256(cleartext_token) — a high-entropy token
--                        → FAST hash (SHA-256), NOT a password hash, per kernel
--                        rule #7, the SAME discipline as tenant_api_keys.key_hash
--                        and org_invites.token_hash. The cleartext is returned
--                        ONCE at issue time (to the IdP admin) and NEVER persisted.
--                        Each token authorizes provisioning into ONE tenant
--                        (tenant_id) and, optionally, a concrete org (org_id) —
--                        VerifyToken(sha256) resolves that pair, which IS the
--                        per-tenant wall: a T1 token can never touch T2's users.
--   public.scim_users  : the SCIM resource <-> org member mapping. One row per
--                        provisioned SCIM User, keyed UNIQUE(tenant_id, scim_id)
--                        so a SCIM id is namespaced PER TENANT (the wall again:
--                        T2 can never GET/PATCH/DELETE a scim_id provisioned under
--                        T1's tenant). It records the GoTrue user_id + org_id the
--                        provisioning landed on, so a deactivate/remove maps back
--                        to the exact org_members row.
--
-- THE LOAD-BEARING CONSTRAINT (D-026): SCIM provisioning is a CONTROL-PLANE
-- operation. It NEVER enters RequestIdentity, the RLS GUCs (app.current_tenant_id
-- / request.tenant_id), or the data plane. SCIM provisions ORG MEMBERS (humans
-- above a project); a tenant still resolves + isolates EXACTLY as today. So
-- per-request isolation + SHARE_POOLS (24,887 tenants -> 1 pool) stay byte-
-- untouched. The provisioning operations call the EXISTING orgs.Service
-- (Add/SetRole/Remove member); SCIM introduces NO new membership concept.
--
-- ISOLATION: house RLS pattern (mirrors tenant_usage 040 / tenant_billing 041 /
-- tenant_backups 042 / tenant_audit_log 047): per-tenant isolation via
-- auth.current_tenant_id(). The control-plane SCIM service writes/reads as the
-- BYPASSRLS service_role and ALWAYS binds tenant_id in its WHERE (the bearer
-- token IS the tenant binding), so a tenant can never read or modify another
-- tenant's SCIM resources even if RLS were misconfigured. authenticated gets
-- SELECT only — a SCIM token (the IdP credential) is issued/revoked exclusively
-- by the service role on the admin path, never minted by a tenant directly.
--
-- The ONE existing-object change is an additive ADD COLUMN IF NOT EXISTS
-- org_members.active (boolean, default true) — back-compatible (every existing
-- member is active), read by NO request-path code (the data plane never selects
-- org_members at all). SCIM `active:false` flips it false (soft deactivate);
-- DELETE removes the membership entirely.
--
-- Running this migration changes NO existing behavior: with SCIM_ENABLED OFF (the
-- default) the /scim/v2/* routes are never mounted, so nothing ever writes
-- scim_tokens / scim_users (they stay empty) and org_members.active stays true
-- for every row = byte-parity baseline (the same story as 040/041/042/043/047).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 54) THEN
    RAISE NOTICE 'Migration 054 already applied - skipping';
    RETURN;
  END IF;

  -- ── scim_tokens: an IdP's SCIM bearer credential (sha256-hashed) ────────────
  -- token_hash stores ONLY lower-hex sha256(cleartext) — UNIQUE so VerifyToken is
  -- a single indexed lookup. tenant_id is the wall: every SCIM call this token
  -- authorizes is scoped to it. org_id is the concrete org provisioning lands on
  -- (nullable: a token may be issued before an org is chosen, but provisioning
  -- requires it to be set).
  CREATE TABLE IF NOT EXISTS public.scim_tokens (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     TEXT        NOT NULL,
    org_id        TEXT,                                          -- concrete org for provisioning (nullable)
    token_hash    TEXT        NOT NULL,                          -- lower-hex sha256(cleartext); UNIQUE
    description   TEXT        NOT NULL DEFAULT '',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at  TIMESTAMPTZ,
    revoked_at    TIMESTAMPTZ,
    CONSTRAINT scim_tokens_token_hash_key UNIQUE (token_hash)
  );
  CREATE INDEX IF NOT EXISTS scim_tokens_tenant_idx ON public.scim_tokens (tenant_id);

  -- ── scim_users: the SCIM resource <-> org member mapping ────────────────────
  -- scim_id is the SCIM resource id (a uuid we mint at create). UNIQUE(tenant_id,
  -- scim_id) namespaces it PER TENANT — the cross-tenant wall (T2 cannot resolve
  -- a scim_id provisioned under T1). user_name is the SCIM `userName` (looked up
  -- by the filter=userName eq "x" query). user_id is the GoTrue user uuid the
  -- provisioning created the membership for; org_id is the org it landed on.
  CREATE TABLE IF NOT EXISTS public.scim_users (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     TEXT        NOT NULL,
    org_id        TEXT,
    scim_id       TEXT        NOT NULL,                          -- SCIM resource id (per-tenant)
    user_name     TEXT        NOT NULL,                          -- SCIM userName
    user_id       TEXT        NOT NULL,                          -- GoTrue user uuid (org_members.user_id)
    display_name  TEXT        NOT NULL DEFAULT '',
    emails        JSONB       NOT NULL DEFAULT '[]'::jsonb,
    active        BOOLEAN     NOT NULL DEFAULT true,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT scim_users_tenant_scim_uniq UNIQUE (tenant_id, scim_id)
  );
  CREATE INDEX IF NOT EXISTS scim_users_tenant_username_idx
    ON public.scim_users (tenant_id, lower(user_name));

  -- ── the ONE existing-object change: soft-deactivate flag on org_members ──────
  -- Additive, default true → every existing member stays active = today's shape.
  -- Read by NO request-path code (the data plane never selects org_members). SCIM
  -- active:false flips it false; DELETE removes the membership row entirely.
  ALTER TABLE public.org_members
    ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT true;

  -- House RLS pattern (mirrors 040–047): per-tenant isolation via
  -- auth.current_tenant_id(). The control-plane SCIM service runs as the
  -- BYPASSRLS service_role (unaffected); only anon/authenticated reads are scoped
  -- to their own tenant rows. It introduces NO new concept into
  -- auth.current_tenant_id() — the function is byte-unchanged.
  ALTER TABLE public.scim_tokens ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.scim_users  ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='scim_tokens' AND policyname='scim_tokens_tenant_isolation'
    ) THEN
      CREATE POLICY scim_tokens_tenant_isolation ON public.scim_tokens
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='scim_users' AND policyname='scim_users_tenant_isolation'
    ) THEN
      CREATE POLICY scim_users_tenant_isolation ON public.scim_users
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- A SCIM token is an IdP credential the platform issues/revokes — the ONLY
  -- legitimate writer is the BYPASSRLS service role on the admin path.
  -- authenticated gets SELECT only on scim_tokens (a tenant can audit which SCIM
  -- credentials exist for it, but can never forge/mutate one). scim_users is the
  -- IdP-driven resource set: authenticated read-only too (writes are SCIM-API
  -- only, service role).
  GRANT SELECT                         ON public.scim_tokens TO authenticated;
  GRANT SELECT, INSERT, UPDATE         ON public.scim_tokens TO service_role;
  GRANT SELECT                         ON public.scim_users  TO authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.scim_users  TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (54, '054_scim_tokens')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- ALTER TABLE public.org_members DROP COLUMN IF EXISTS active;
-- DROP TABLE IF EXISTS public.scim_users;
-- DROP TABLE IF EXISTS public.scim_tokens;
-- DELETE FROM public.schema_migrations WHERE version = 54;
-- COMMIT;
