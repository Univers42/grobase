-- File: scripts/migrations/postgresql/046_tenant_telemetry_targets.sql
-- Migration 046: per-tenant TELEMETRY EXPORT targets (Track-C C9).
--
-- ADDITIVE ONLY. Creates the durable config the flag-gated C9 telemetry exporter
-- consumes: per tenant, WHERE to ship that tenant's own telemetry (logs/usage
-- metrics) — a customer-configured OTLP/HTTP or log-drain collector — plus an
-- optional auth header and an explicit per-row enable flag. C9 is the BYO-collector
-- complement to B5 (per-tenant observability): B5 makes tenant_id a queryable LOG
-- FIELD inside Grobase's own Loki/Grafana; C9 forwards a SINGLE tenant's telemetry
-- OUT to THAT tenant's collector, attributed to it.
--
-- Migration number 046 follows 045_tenant_safety (043/044 are reserved for the
-- planned D1 org model) so this Track-C slice never collides with that keystone.
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With TENANT_TELEMETRY_EXPORT_ENABLED OFF (the default) nothing
-- ever reads this table on any path and no row is ever inserted by the platform, so
-- it stays empty = byte-parity baseline (the same story as 040/041/042/045). The
-- exporter, when enabled, reads as the BYPASSRLS control-plane role exactly like the
-- metering consumer / QuotaGuard / spend-cap guard; the RLS + grant pattern mirrors
-- 040_tenant_usage so any tenant-facing read of its OWN target is isolated by
-- construction (a tenant can only ever see its own export config).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 46) THEN
    RAISE NOTICE 'Migration 046 already applied - skipping';
    RETURN;
  END IF;

  -- One row per tenant that has opted in to telemetry export. A tenant with NO row
  -- here (the default for every tenant) is NEVER exported — the safe, byte-parity
  -- baseline. `endpoint` is the customer's collector URL (OTLP/HTTP logs endpoint
  -- or a generic log-drain HTTP sink); `auth_header` is an OPTIONAL bearer/secret
  -- header value the exporter sends as Authorization (NULL → no auth header).
  -- `format` selects the wire shape: 'otlp' (OTLP/HTTP logs JSON) or 'ndjson'
  -- (newline-delimited JSON log-drain). `enabled` is an explicit per-row kill
  -- switch so an operator can pause one tenant's export without deleting its config.
  CREATE TABLE IF NOT EXISTS public.tenant_telemetry_targets (
    tenant_id     TEXT        PRIMARY KEY,
    endpoint      TEXT        NOT NULL,
    auth_header   TEXT,                                      -- NULL = no Authorization header
    format        TEXT        NOT NULL DEFAULT 'otlp'
                  CHECK (format IN ('otlp','ndjson')),
    enabled       BOOLEAN     NOT NULL DEFAULT TRUE,         -- per-tenant pause switch
    last_cursor   TIMESTAMPTZ NOT NULL DEFAULT to_timestamp(0), -- high-water mark of exported usage windows
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- The exporter scans the opted-in + enabled rows each tick.
  CREATE INDEX IF NOT EXISTS tenant_telemetry_targets_enabled_idx
    ON public.tenant_telemetry_targets (enabled);

  -- House RLS pattern (mirrors tenant_usage / webhook_subscriptions): per-tenant
  -- isolation via auth.current_tenant_id(). The exporter writes/reads as the
  -- BYPASSRLS control-plane role (unaffected); anon/authenticated only ever see
  -- their OWN target row — a tenant can never read or alter another tenant's
  -- export endpoint, so the export destination cannot be cross-tenant by config.
  ALTER TABLE public.tenant_telemetry_targets ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'tenant_telemetry_targets'
         AND policyname = 'tenant_telemetry_targets_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_telemetry_targets_tenant_isolation ON public.tenant_telemetry_targets
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- Re-affirm the legitimate reader/writer grants explicitly (the 001 blanket-grant
  -- story; see migration 039). service_role is BYPASSRLS anyway.
  GRANT SELECT, INSERT, UPDATE ON public.tenant_telemetry_targets TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (46, '046_tenant_telemetry_targets')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.tenant_telemetry_targets;
-- DELETE FROM public.schema_migrations WHERE version = 46;
-- COMMIT;
