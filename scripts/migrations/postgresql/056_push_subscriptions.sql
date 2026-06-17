-- File: scripts/migrations/postgresql/056_push_subscriptions.sql
-- Migration 056: per-tenant PUSH / MESSAGING subscriptions (Track-E, Firebase
-- FCM-parity). The flag-gated push API (PUSH_ENABLED, default OFF) lets a tenant
-- register notification SUBSCRIPTIONS and SEND a notification that fans out to
-- every matching subscription over an outbound HTTP POST.
--
-- ADDITIVE ONLY. Creates ONE control-plane table; touches no existing object.
--
--   public.push_subscriptions : one row per registered delivery target. `channel`
--       is 'webhook' (a plain HTTP endpoint the tenant owns) or 'fcm' (an
--       FCM-COMPATIBLE HTTP endpoint — both are an HTTP POST to a configured
--       target_url, so 'fcm' is just a pluggable provider endpoint; no real FCM
--       SDK is required). `token_enc` optionally stores a provider auth token
--       AES-256-GCM SEALED (the push service seals it with PUSH_SECRET_KEY,
--       nonce||ciphertext+tag, the SAME fold internal/sso uses) — nullable
--       because the webhook channel needs no token. `user_id` optionally narrows
--       a send to a single subscriber. `revoked_at` soft-deletes (a revoked
--       subscription is never a delivery target).
--
-- THE LOAD-BEARING CONSTRAINT (D-026): push is a CONTROL-PLANE feature. It NEVER
-- enters RequestIdentity, the RLS GUCs (app.current_tenant_id / request.tenant_id),
-- or the data plane. A tenant still resolves + isolates EXACTLY as today, so
-- per-request isolation + SHARE_POOLS (24,887 tenants -> 1 pool) stay byte-
-- untouched. tenant_id is bound in EVERY query the push service runs (it reads as
-- the BYPASSRLS service_role, so the WHERE tenant_id IS the wall — a send in one
-- tenant can never deliver to another tenant's subscriptions).
--
-- ISOLATION: house RLS pattern (mirrors tenant_usage 040 / tenant_billing 041 /
-- tenant_backups 042 / tenant_audit_log 047 / tenant_exports 052 / scim_* 054):
-- per-tenant isolation via auth.current_tenant_id(). The control-plane push
-- service runs as the BYPASSRLS service_role and ALWAYS binds tenant_id; anon/
-- authenticated reads are scoped to their own tenant rows. A push token (a
-- provider credential) is sealed at rest, NEVER returned by list/get.
--
-- Running this migration changes NO existing behavior: with PUSH_ENABLED OFF (the
-- default) the /v1/tenants/{id}/push/* routes are never mounted, so nothing ever
-- writes push_subscriptions (it stays empty) = byte-parity baseline (the same
-- story as 040/041/042/047/052/054).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 56) THEN
    RAISE NOTICE 'Migration 056 already applied - skipping';
    RETURN;
  END IF;

  -- One row per delivery target. channel CHECK forbids any value other than the
  -- two advertised channels (webhook | fcm) structurally — the service additionally
  -- validates, but the table is the last wall. token_enc is the AES-256-GCM SEALED
  -- provider token (nonce(12)||ciphertext+tag); NULL for the webhook channel.
  CREATE TABLE IF NOT EXISTS public.push_subscriptions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   TEXT        NOT NULL,
    user_id     TEXT,                                       -- optional: narrow a send to one subscriber
    channel     TEXT        NOT NULL CHECK (channel IN ('webhook','fcm')),
    target_url  TEXT        NOT NULL,                       -- the HTTP POST endpoint (webhook URL or FCM-compatible)
    token_enc   BYTEA,                                      -- AES-256-GCM sealed provider token (nullable)
    label       TEXT        NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at  TIMESTAMPTZ
  );

  -- List/send scan by (tenant, live-only): WHERE tenant_id=$1 AND revoked_at IS NULL.
  CREATE INDEX IF NOT EXISTS push_subscriptions_tenant_idx
    ON public.push_subscriptions (tenant_id) WHERE revoked_at IS NULL;

  -- House RLS pattern (mirrors 040–054): per-tenant isolation via
  -- auth.current_tenant_id(). The control-plane push service writes/reads as the
  -- BYPASSRLS service_role (unaffected) and ALWAYS binds tenant_id in its WHERE;
  -- only anon/authenticated reads are scoped to their own tenant rows. It
  -- introduces NO new concept into auth.current_tenant_id() — the function is
  -- byte-unchanged.
  ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'push_subscriptions'
         AND policyname = 'push_subscriptions_tenant_isolation'
    ) THEN
      CREATE POLICY push_subscriptions_tenant_isolation ON public.push_subscriptions
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- service_role is BYPASSRLS, but re-affirm the legitimate writer/reader grants
  -- explicitly (the 001 blanket-grant story; mirrors 040 / 041 / 042 / 052 / 054).
  -- authenticated gets SELECT only — a subscription's sealed token is never
  -- mutated by a tenant directly; registration/revocation runs the service path.
  GRANT SELECT                         ON public.push_subscriptions TO authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (56, '056_push_subscriptions')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.push_subscriptions;
-- DELETE FROM public.schema_migrations WHERE version = 56;
-- COMMIT;
