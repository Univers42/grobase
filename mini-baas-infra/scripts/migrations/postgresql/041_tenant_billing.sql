-- File: scripts/migrations/postgresql/041_tenant_billing.sql
-- Migration 041: per-tenant Stripe billing map + sent-ledger (Track-B B3).
--
-- ADDITIVE ONLY. Creates the two durable tables the flag-gated billing reporter
-- (BILLING_ENABLED, default OFF) needs to push B1 usage to Stripe's billing
-- meters WITHOUT re-metering and WITHOUT double-counting:
--
--   public.tenant_billing  : maps a tenant -> its Stripe customer (+ subscription
--                            + current plan). A tenant with NO row here is simply
--                            not billed (the reporter skips it) -> safe default.
--   public.billing_reported: the local sent-ledger. One row per usage WINDOW the
--                            reporter has already pushed (PK = the window's B1
--                            idempotency_key). The reporter only POSTs windows
--                            absent from this ledger, so a re-tick never re-sends a
--                            window -> idempotent regardless of Stripe's own dedup.
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With BILLING_ENABLED OFF (the default) nothing ever writes to
-- either table, so they stay empty = byte-parity baseline. Mirrors the RLS +
-- grant pattern of 040_tenant_usage / 031_webhook_subscriptions: per-tenant
-- isolation for any tenant-facing read; the control-plane reporter writes as the
-- BYPASSRLS service role.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 41) THEN
    RAISE NOTICE 'Migration 041 already applied - skipping';
    RETURN;
  END IF;

  -- tenant -> Stripe customer mapping. tenant_id is the PK (one billing identity
  -- per tenant). stripe_customer_id may be '' transiently (tenant created but not
  -- yet onboarded to billing) — the reporter skips empty-customer rows.
  CREATE TABLE IF NOT EXISTS public.tenant_billing (
    tenant_id              TEXT        PRIMARY KEY,
    stripe_customer_id     TEXT        NOT NULL DEFAULT '',
    stripe_subscription_id TEXT        NOT NULL DEFAULT '',
    plan                   TEXT        NOT NULL DEFAULT '',
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- Local sent-ledger: one row per already-reported usage window. PK is the B1
  -- idempotency_key (sha256("<tenant>|<metric>|<window_start_ms>")) so it lines up
  -- 1:1 with public.tenant_usage rows. The reporter LEFT JOINs tenant_usage to
  -- this and only sends windows with no ledger row.
  CREATE TABLE IF NOT EXISTS public.billing_reported (
    idempotency_key TEXT        PRIMARY KEY,
    tenant_id       TEXT        NOT NULL,
    metric          TEXT        NOT NULL,
    qty             BIGINT      NOT NULL DEFAULT 0,
    reported_at     TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- The reporter scans tenant_billing by tenant during the usage JOIN; the ledger
  -- is probed by idempotency_key (the PK already covers that). A tenant-scoped
  -- index on the ledger helps per-tenant usage views (B4 dashboard).
  CREATE INDEX IF NOT EXISTS billing_reported_tenant_idx
    ON public.billing_reported (tenant_id, reported_at);

  -- House RLS pattern (mirrors tenant_usage / webhook_subscriptions): per-tenant
  -- isolation via auth.current_tenant_id(). The reporter writes/reads as the
  -- BYPASSRLS service role, so it is unaffected; only anon/authenticated are
  -- scoped to their own rows (B4 will surface a tenant's own billing state).
  ALTER TABLE public.tenant_billing   ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.billing_reported ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='tenant_billing' AND policyname='tenant_billing_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_billing_tenant_isolation ON public.tenant_billing
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='billing_reported' AND policyname='billing_reported_tenant_isolation'
    ) THEN
      CREATE POLICY billing_reported_tenant_isolation ON public.billing_reported
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  GRANT SELECT, INSERT, UPDATE ON public.tenant_billing   TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE ON public.billing_reported TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (41, '041_tenant_billing')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.billing_reported;
-- DROP TABLE IF EXISTS public.tenant_billing;
-- DELETE FROM public.schema_migrations WHERE version = 41;
-- COMMIT;
