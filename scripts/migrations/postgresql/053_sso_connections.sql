# File: scripts/migrations/postgresql/053_sso_connections.sql
# Migration 053: enterprise OIDC SSO connections (Track-D D2a).
#
# ADDITIVE ONLY. Creates the durable per-tenant registry of OIDC identity-provider
# connections the flag-gated SSO login flow (SSO_ENABLED, default OFF) reads. One
# row is ONE configured IdP for ONE tenant (optionally scoped to one org_id): the
# issuer + endpoints + client credentials needed to drive an authorization-code
# exchange and verify the returned id_token. `client_secret_enc` is AES-256-GCM
# CIPHERTEXT (sealed IN GO with a key from SSO_SECRET_KEY) — the plaintext secret
# is never stored, the same discipline funcsecrets / adapterregistry use.
#
# ISOLATION: house RLS pattern (mirrors tenant_usage 040 / tenant_audit_log 047):
# per-tenant isolation via auth.current_tenant_id(). The control-plane SSO service
# writes/reads as the BYPASSRLS service_role and ALWAYS binds tenant_id in its
# WHERE (defense-in-depth), so a tenant can never read another tenant's IdP
# connections even if RLS were misconfigured. authenticated gets SELECT only —
# the only legitimate writer is the service role on the admin register path; a
# tenant credential can read its own connections (to render a login button) but
# can never forge, mutate, or delete one, and can never read the sealed secret in
# usable form (it is ciphertext, and only the control plane holds the key).
#
# Running this migration changes NO existing behavior (no ALTER/DROP of any
# existing object). With SSO_ENABLED OFF (the default) the /v1/auth/sso/* routes
# are never mounted, so nothing ever writes to this table, so it stays empty =
# byte-parity baseline (same story as 040 / 047 / 050 / 051 / 052).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 53) THEN
    RAISE NOTICE 'Migration 053 already applied - skipping';
    RETURN;
  END IF;

  -- One row per (tenant, IdP). `issuer` is the OIDC issuer identifier (the `iss`
  -- claim the id_token MUST carry); `client_id` is the OIDC client / `aud` the
  -- id_token MUST be addressed to. `client_secret_enc` is AES-256-GCM ciphertext
  -- (12-byte nonce prefix || ciphertext+tag) sealed in Go; the plaintext is never
  -- stored. `authorize_url` / `token_url` are the IdP's authorization + token
  -- endpoints; `jwks_url` is the IdP's public-key set (NULL for HS256 shared-secret
  -- dev/mock IdPs). `email_domain` lets BeginLogin resolve a connection by the
  -- user's email domain (e.g. acme.com -> the Acme IdP). `default_role` is the org
  -- role a JIT-provisioned member receives (recorded for downstream provisioning;
  -- the minted session JWT itself is the standard authenticated session shape).
  CREATE TABLE IF NOT EXISTS public.sso_connections (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         TEXT        NOT NULL,
    org_id            TEXT,                                  -- optional org scope (NULL = tenant-wide)
    provider          TEXT        NOT NULL DEFAULT 'oidc',
    issuer            TEXT        NOT NULL,                  -- OIDC `iss` the id_token must carry
    client_id         TEXT        NOT NULL,                  -- OIDC client / id_token `aud`
    client_secret_enc BYTEA,                                 -- AES-256-GCM(nonce||ct+tag) sealed in Go
    authorize_url     TEXT        NOT NULL,                  -- IdP authorization endpoint
    token_url         TEXT        NOT NULL,                  -- IdP token endpoint
    jwks_url          TEXT,                                  -- IdP JWKS (NULL = HS256 shared-secret IdP)
    redirect_uri      TEXT        NOT NULL,                  -- our /v1/auth/sso/callback URL
    email_domain      TEXT,                                  -- optional: resolve connection by email domain
    default_role      TEXT        NOT NULL DEFAULT 'member',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- a tenant cannot register the SAME issuer twice (one IdP, one connection).
    CONSTRAINT sso_connections_tenant_issuer_uniq UNIQUE (tenant_id, issuer)
  );

  -- BeginLogin resolves a connection by id (UNIQUE pk) or by email_domain; the
  -- domain lookup is scoped to the tenant, so an index over (tenant_id, email_domain)
  -- keeps it cheap and the tenant filter mandatory.
  CREATE INDEX IF NOT EXISTS sso_connections_tenant_domain_idx
    ON public.sso_connections (tenant_id, email_domain);

  -- House RLS pattern (mirrors tenant_usage / tenant_audit_log): per-tenant
  -- isolation via auth.current_tenant_id(). The control-plane SSO service
  -- writes/reads as the BYPASSRLS service_role (unaffected); anon/authenticated
  -- reads are scoped to their own tenant rows only.
  ALTER TABLE public.sso_connections ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'sso_connections'
         AND policyname = 'sso_connections_tenant_isolation'
    ) THEN
      CREATE POLICY sso_connections_tenant_isolation ON public.sso_connections
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- Write is service-role-only: the ONLY legitimate writer is the BYPASSRLS
  -- service role on the admin register path. authenticated gets SELECT only — no
  -- INSERT/UPDATE/DELETE — so a tenant can read its own connections (to render a
  -- login button) but can never forge, mutate, or delete one. (service_role is
  -- BYPASSRLS but we re-affirm its write grants explicitly, the 001 blanket-grant
  -- story / 047 / 052.)
  GRANT SELECT                 ON public.sso_connections TO authenticated;
  GRANT SELECT, INSERT, UPDATE ON public.sso_connections TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (53, '053_sso_connections')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.sso_connections;
-- DELETE FROM public.schema_migrations WHERE version = 53;
-- COMMIT;
