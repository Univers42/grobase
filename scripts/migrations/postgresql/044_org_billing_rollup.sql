-- File: scripts/migrations/postgresql/044_org_billing_rollup.sql
-- Migration 044: per-org billing rollup (Track-D D1.5).
--
-- ADDITIVE ONLY. Mirrors 041_tenant_billing.sql exactly (one Stripe identity per
-- org; usage rolls UP from the per-project tenant_usage rows, per-project qty
-- PRESERVED, never re-metered) for the flag-gated org rollup
-- (ORG_BILLING_ROLLUP_ENABLED, default OFF):
--
--   public.org_billing          : maps an org -> its Stripe customer (+ subscription
--                                 + current plan). An org with NO row here is simply
--                                 not billed at the org level -> safe default.
--   public.org_billing_reported : the local sent-ledger. One row per (org, metric,
--                                 window) already pushed (PK = the window's
--                                 idempotency_key). A re-tick never re-sends a window.
--   public.org_usage_rollup     : a read-only VIEW that SUMs public.tenant_usage by
--                                 metric for every project where tenants.org_id is
--                                 set. Per-project tenant_usage rows are NEVER
--                                 mutated — the rollup is a read-only aggregation, so
--                                 B1 metering parity is untouched.
--
-- Migration number 044 was RESERVED for exactly this slice by 045_tenant_safety.sql
-- ("043 org data model, 044 per-org billing rollup").
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With ORG_BILLING_ROLLUP_ENABLED OFF (the default) no writer
-- runs, so org_billing / org_billing_reported stay empty = byte-parity baseline
-- (the same story as 040 / 041 / 042 / 043 / 045). The org_usage_rollup VIEW is
-- inert until the org model is populated (it reads tenants.org_id, which is NULL
-- for every existing tenant) and never writes anything.
--
-- Coexistence with B3 per-tenant billing: a project with org_id IS NOT NULL is
-- billed via its org's org_billing; a project with org_id IS NULL keeps the
-- existing per-tenant tenant_billing path (B3). Neither path double-bills, and the
-- per-project tenant_usage numbers stay the single source of truth.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 44) THEN
    RAISE NOTICE 'Migration 044 already applied - skipping';
    RETURN;
  END IF;

  -- org -> Stripe customer mapping. org_id is the PK (one billing identity per
  -- org). stripe_customer_id may be '' transiently (org created but not yet
  -- onboarded to billing) — the rollup reporter skips empty-customer rows.
  CREATE TABLE IF NOT EXISTS public.org_billing (
    org_id                 UUID        PRIMARY KEY REFERENCES public.orgs(id) ON DELETE CASCADE,
    stripe_customer_id     TEXT        NOT NULL DEFAULT '',
    stripe_subscription_id TEXT        NOT NULL DEFAULT '',
    plan                   TEXT        NOT NULL DEFAULT '',
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- Local sent-ledger: one row per already-reported usage window. PK is the
  -- idempotency_key (sha256("<org_id>|<metric>|<window_ms>")) so a re-tick never
  -- re-sends a window (mirrors billing_reported, 041_tenant_billing.sql).
  CREATE TABLE IF NOT EXISTS public.org_billing_reported (
    idempotency_key TEXT        PRIMARY KEY,
    org_id          UUID        NOT NULL,
    metric          TEXT        NOT NULL,
    qty             BIGINT      NOT NULL DEFAULT 0,
    reported_at     TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE INDEX IF NOT EXISTS org_billing_reported_org_idx
    ON public.org_billing_reported (org_id, reported_at);

  -- READ-ONLY rollup view: SUM the per-project usage (the SINGLE source of truth,
  -- 040_tenant_usage) for every project attached to an org. Per-project rows are
  -- never mutated; this is a pure aggregation. NULL org_id projects (the pre-D1
  -- shape) are excluded by the join, so the view is inert until orgs are populated.
  CREATE OR REPLACE VIEW public.org_usage_rollup AS
    SELECT t.org_id,
           u.metric,
           COALESCE(SUM(u.qty), 0)::bigint AS qty,
           COUNT(*)::bigint                AS window_count
      FROM public.tenant_usage u
      JOIN public.tenants t ON t.slug = u.tenant_id
     WHERE t.org_id IS NOT NULL
     GROUP BY t.org_id, u.metric;

  ALTER TABLE public.org_billing          ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.org_billing_reported ENABLE ROW LEVEL SECURITY;

  -- Visible to org members (billing/admin/owner gate enforced in Go; RLS = 2nd
  -- wall). The control-plane rollup reporter writes as the BYPASSRLS service role.
  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='org_billing' AND policyname='org_billing_member_visibility'
    ) THEN
      CREATE POLICY org_billing_member_visibility ON public.org_billing FOR SELECT USING (
        EXISTS (SELECT 1 FROM public.org_members m
                 WHERE m.org_id = org_billing.org_id AND m.user_id = auth.current_user_id()::text));
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='org_billing_reported' AND policyname='org_billing_reported_member_visibility'
    ) THEN
      CREATE POLICY org_billing_reported_member_visibility ON public.org_billing_reported FOR SELECT USING (
        EXISTS (SELECT 1 FROM public.org_members m
                 WHERE m.org_id = org_billing_reported.org_id AND m.user_id = auth.current_user_id()::text));
    END IF;
  END $pol$;

  GRANT SELECT, INSERT, UPDATE ON public.org_billing          TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE ON public.org_billing_reported TO authenticated, service_role;
  GRANT SELECT                 ON public.org_usage_rollup     TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (44, '044_org_billing_rollup')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP VIEW  IF EXISTS public.org_usage_rollup;
-- DROP TABLE IF EXISTS public.org_billing_reported;
-- DROP TABLE IF EXISTS public.org_billing;
-- DELETE FROM public.schema_migrations WHERE version = 44;
-- COMMIT;
