-- 071_vault42_secrets.sql — the vault42 zero-knowledge blob substrate (grobase-side).
--
-- Additive + idempotent. ZERO plaintext columns: `envelope` is an OPAQUE serialized
-- vault42-core Envelope the server can never decrypt (`author_pubkey` is a PUBLIC key kept
-- as a verification sidecar). Owner-scoped to the data-plane's TEXT principal — the same
-- value `apply_rls_context` stamps into `app.current_user_id` and `crud_build` writes into
-- `owner_id` (tx.rs:91,103). These tables are reached ONLY through the `/query/v1` data
-- plane, never the public PostgREST `/rest/v1` surface, so anon/authenticated are revoked
-- and only service_role keeps access (the 065 least-privilege pattern). Read owner-scoping
-- on the live (superuser) path comes from the mount's `read_scoped=true`; the RLS policy +
-- FORCE here is defense-in-depth that stays correct if the data plane ever drops superuser.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 71) THEN
    RAISE NOTICE 'Migration 071 already applied - skipping';
    RETURN;
  END IF;

  -- The opaque secret blobs (one row per owner/path/version).
  CREATE TABLE IF NOT EXISTS public.vault42_secrets (
    owner_id      text        NOT NULL,
    path          text        NOT NULL,
    secret_id     text        NOT NULL,
    version       integer     NOT NULL,
    envelope      bytea       NOT NULL,
    author_pubkey bytea       NOT NULL,
    updated_at    bigint      NOT NULL,
    PRIMARY KEY (owner_id, path, version)
  );
  CREATE INDEX IF NOT EXISTS vault42_secrets_owner_path
    ON public.vault42_secrets (owner_id, path);

  ALTER TABLE public.vault42_secrets ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.vault42_secrets FORCE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS vault42_secrets_owner ON public.vault42_secrets;
  CREATE POLICY vault42_secrets_owner ON public.vault42_secrets
    FOR ALL
    USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
    WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
  REVOKE ALL ON public.vault42_secrets FROM anon, authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.vault42_secrets TO service_role;

  -- The per-owner tamper-evident audit chain (hash-linked).
  CREATE TABLE IF NOT EXISTS public.vault42_audit (
    owner_id  text   NOT NULL,
    seq       bigint NOT NULL,
    ts        bigint NOT NULL,
    actor     text   NOT NULL,
    action    text   NOT NULL,
    target    text   NOT NULL,
    prev_hash text   NOT NULL,
    hash      text   NOT NULL,
    PRIMARY KEY (owner_id, seq)
  );

  ALTER TABLE public.vault42_audit ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.vault42_audit FORCE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS vault42_audit_owner ON public.vault42_audit;
  CREATE POLICY vault42_audit_owner ON public.vault42_audit
    FOR ALL
    USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
    WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
  REVOKE ALL ON public.vault42_audit FROM anon, authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.vault42_audit TO service_role;

  -- Time-bound RBAC leases (tenant-scoped; future authz, harmless empty today).
  CREATE TABLE IF NOT EXISTS public.vault42_grants (
    id             uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant         text        NOT NULL,
    grantee        text        NOT NULL,
    role           text        NOT NULL CHECK (role IN ('read','write','update','admin')),
    resource_scope text        NOT NULL DEFAULT '*',
    granted_by     text        NOT NULL,
    granted_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    revoked_at     timestamptz NULL,
    PRIMARY KEY (id)
  );
  CREATE INDEX IF NOT EXISTS vault42_grants_lookup
    ON public.vault42_grants (tenant, grantee, role) WHERE revoked_at IS NULL;

  ALTER TABLE public.vault42_grants ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.vault42_grants FORCE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS vault42_grants_tenant ON public.vault42_grants;
  CREATE POLICY vault42_grants_tenant ON public.vault42_grants
    FOR ALL
    USING      (tenant = NULLIF(current_setting('app.current_tenant_id', true), ''))
    WITH CHECK (tenant = NULLIF(current_setting('app.current_tenant_id', true), ''));
  REVOKE ALL ON public.vault42_grants FROM anon, authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.vault42_grants TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (71, '071_vault42_secrets') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
