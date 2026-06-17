-- File: scripts/migrations/postgresql/040_tenant_usage.sql
-- Migration 040: per-tenant usage-metering aggregate (Track-B B1b).
--
-- ADDITIVE ONLY. Creates the durable sink for the flag-gated usage pipeline:
-- the data plane (DATA_PLANE_METERING) and extra planes emit windowed
-- (tenant_id, metric, qty, ts) rollups onto the `usage.events` Redis stream;
-- the control-plane metering consumer (METERING_INGEST) idempotently UPSERTs
-- them here. Rows are tenant-scoped via RLS exactly like webhook_subscriptions
-- (031) and tenant_databases (016) — owner-scoped reads for free in B1c.
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With every metering flag OFF (the default), nothing ever
-- writes to this table, so it stays empty = byte-parity baseline. The table is
-- the producer/consumer boundary for the FROZEN envelope contract:
--   idempotency_key = lower-hex sha256("<tenant_id>|<metric>|<window_start_ms>")
--   ON CONFLICT (idempotency_key) DO NOTHING  -> a re-delivered identical window
--   never double-counts (at-least-once Redis-stream delivery -> dedup on ingest).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 40) THEN
    RAISE NOTICE 'Migration 040 already applied - skipping';
    RETURN;
  END IF;

  -- The aggregate table. One row per (tenant, metric, window); qty is the
  -- summed work in that window. idempotency_key is the PK so a re-delivered
  -- identical window is a no-op (DO NOTHING), never a double-count.
  CREATE TABLE IF NOT EXISTS public.tenant_usage (
    tenant_id        TEXT        NOT NULL,
    metric           TEXT        NOT NULL,
    window_start     TIMESTAMPTZ NOT NULL,
    qty              BIGINT      NOT NULL DEFAULT 0,
    idempotency_key  TEXT        PRIMARY KEY,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- Read API (B1c) and B2 enforcement both scan by (tenant, metric, window):
  -- SELECT qty FROM tenant_usage WHERE tenant AND metric AND window>=... .
  CREATE INDEX IF NOT EXISTS tenant_usage_lookup_idx
    ON public.tenant_usage (tenant_id, metric, window_start);

  -- House RLS pattern (mirrors webhook_subscriptions / tenant_databases):
  -- per-tenant isolation via auth.current_tenant_id(). The ingest consumer
  -- writes as the postgres superuser / service_role (BYPASSRLS), so it is
  -- unaffected; only anon/authenticated are scoped to their own tenant rows.
  ALTER TABLE public.tenant_usage ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'tenant_usage'
         AND policyname = 'tenant_usage_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_usage_tenant_isolation ON public.tenant_usage
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- service_role is BYPASSRLS, but re-affirm the legitimate consumer/reader
  -- grants explicitly (the 001 blanket-grant story; see migration 039).
  GRANT SELECT, INSERT, UPDATE ON public.tenant_usage TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (40, '040_tenant_usage')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.tenant_usage;
-- DELETE FROM public.schema_migrations WHERE version = 40;
-- COMMIT;
