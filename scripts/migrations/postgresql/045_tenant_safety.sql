-- File: scripts/migrations/postgresql/045_tenant_safety.sql
-- Migration 045: B7 cloud-go-live SAFETY + COMMERCE primitives (Track-B B7.8/B7.9).
--
-- ADDITIVE ONLY. Creates the durable state the flag-gated B7 guards need to make a
-- public free tier defensible against cost-runaway and abuse:
--
--   public.tenant_budgets    : per-tenant monthly budget threshold + alert state for
--                              the SPEND-CAP guard (SPEND_CAPS_ENABLED, default OFF).
--                              A tenant with NO row here has NO budget cap → never
--                              halted (the safe pre-B7.8 default).
--   public.tenant_safety     : per-tenant abuse/KYC state for the ABUSE guard
--                              (ABUSE_GUARD_ENABLED, default OFF): email/phone-verify
--                              flags, a pay-method flag, an abuse flag, and the
--                              suspension state. A tenant with NO row defaults to
--                              "verified-not-required, not-suspended" so the baseline
--                              free of the guard is byte-parity.
--   public.principal_events  : an append-only velocity ledger — one row per sensitive
--                              action (project_create) by a principal, used by the
--                              ABUSE guard's per-principal velocity limiter. Empty
--                              until the guard is enabled and admits/denies a call.
--
-- Migration number 045 is deliberately chosen to leave 043/044 free for the planned
-- D1 org model (043 org data model, 044 per-org billing rollup) so this safety slice
-- never collides with that keystone work.
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any existing
-- object). With SPEND_CAPS_ENABLED and ABUSE_GUARD_ENABLED OFF (the defaults) nothing
-- ever reads or writes these tables on a request path, so they stay empty = byte-
-- parity baseline (the same story as 040 / 041 / 042). Mirrors the RLS + grant
-- pattern of 040_tenant_usage / 041_tenant_billing / 042_tenant_backups: per-tenant
-- isolation for any tenant-facing read; the control-plane guards write/read as the
-- BYPASSRLS service role.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 45) THEN
    RAISE NOTICE 'Migration 045 already applied - skipping';
    RETURN;
  END IF;

  -- ── B7.8 spend caps ─────────────────────────────────────────────────────────
  -- Per-tenant budget in whole CENTS (avoid float money). `budget_cents` is the
  -- HARD cap that STOPS billable service; the 80% (configurable) ALERT fires once
  -- per period and is recorded in `alert_fired_period` (the period-start the alert
  -- last fired for) so it never re-fires within the same period. A tenant with no
  -- row here has no cap and is never halted (safe default). period mirrors B2.
  CREATE TABLE IF NOT EXISTS public.tenant_budgets (
    tenant_id          TEXT        PRIMARY KEY,
    budget_cents       BIGINT      NOT NULL DEFAULT 0,   -- 0 = unlimited (no hard cap)
    period             TEXT        NOT NULL DEFAULT 'month'
                       CHECK (period IN ('hour','day','month')),
    alert_fired_period TIMESTAMPTZ,                      -- period-start the 80% alert last fired for
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- ── B7.9 abuse / free-tier KYC-lite ────────────────────────────────────────
  -- Per-tenant verification + abuse + suspension state. Defaults are the
  -- byte-parity baseline: not flagged, not suspended, verification not asserted.
  -- The guard reads `email_verified` / `phone_verified` / `pay_method` only for
  -- tiers/actions that REQUIRE them (env-driven); `abuse_flag` true OR a velocity
  -- breach flips `suspended` true with a `suspended_reason`.
  CREATE TABLE IF NOT EXISTS public.tenant_safety (
    tenant_id        TEXT        PRIMARY KEY,
    email_verified   BOOLEAN     NOT NULL DEFAULT false,
    phone_verified   BOOLEAN     NOT NULL DEFAULT false,
    pay_method       BOOLEAN     NOT NULL DEFAULT false,  -- a usable payment method on file
    abuse_flag       BOOLEAN     NOT NULL DEFAULT false,  -- operator/heuristic abuse mark
    suspended        BOOLEAN     NOT NULL DEFAULT false,
    suspended_reason TEXT,
    suspended_at     TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- Append-only velocity ledger. One row per sensitive action by a principal
  -- (api-key:<uuid> or user:<id>). The guard COUNTs rows in a sliding window to
  -- decide a velocity breach. `tenant_id` is carried for RLS scoping + per-tenant
  -- views; `principal` is the velocity key (a principal may act across tenants).
  CREATE TABLE IF NOT EXISTS public.principal_events (
    id          BIGSERIAL   PRIMARY KEY,
    principal   TEXT        NOT NULL,
    tenant_id   TEXT        NOT NULL DEFAULT '',
    action      TEXT        NOT NULL,        -- e.g. 'project_create'
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- Velocity COUNTs scan by (principal, action, recent window): the index makes the
  -- sliding-window count a range scan, not a seq scan, as the ledger grows.
  CREATE INDEX IF NOT EXISTS principal_events_velocity_idx
    ON public.principal_events (principal, action, created_at DESC);

  -- House RLS pattern (mirrors tenant_usage 040 / tenant_billing 041 /
  -- tenant_backups 042): per-tenant isolation via auth.current_tenant_id(). The
  -- control-plane guards write/read as the BYPASSRLS service_role, so they are
  -- unaffected; only anon/authenticated self-serve reads are scoped to own rows.
  ALTER TABLE public.tenant_budgets   ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.tenant_safety    ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.principal_events ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='tenant_budgets' AND policyname='tenant_budgets_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_budgets_tenant_isolation ON public.tenant_budgets
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='tenant_safety' AND policyname='tenant_safety_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_safety_tenant_isolation ON public.tenant_safety
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='principal_events' AND policyname='principal_events_tenant_isolation'
    ) THEN
      CREATE POLICY principal_events_tenant_isolation ON public.principal_events
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- service_role is BYPASSRLS, but re-affirm the legitimate writer/reader grants
  -- explicitly (the 001 blanket-grant story; mirrors 040 / 041 / 042).
  GRANT SELECT, INSERT, UPDATE ON public.tenant_budgets   TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE ON public.tenant_safety    TO authenticated, service_role;
  GRANT SELECT, INSERT         ON public.principal_events TO authenticated, service_role;
  GRANT USAGE, SELECT ON SEQUENCE public.principal_events_id_seq TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (45, '045_tenant_safety')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.principal_events;
-- DROP TABLE IF EXISTS public.tenant_safety;
-- DROP TABLE IF EXISTS public.tenant_budgets;
-- DELETE FROM public.schema_migrations WHERE version = 45;
-- COMMIT;
