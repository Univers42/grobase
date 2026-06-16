-- File: scripts/migrations/postgresql/031_webhooks.sql
-- Migration 031: webhook subscriptions + delivery ledger (DLQ).
--
-- Webhooks let tenants subscribe to outbox events (orders.created, etc.)
-- and receive HMAC-signed POSTs at an arbitrary URL with retry + DLQ.
-- Owned by webhook-dispatcher (Go service); rows are tenant-scoped via RLS.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 31) THEN
    RAISE NOTICE 'Migration 031 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.webhook_subscriptions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT NOT NULL,
    name            TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
    url             TEXT NOT NULL CHECK (url ~ '^https?://'),
    secret          TEXT NOT NULL,
    event_types     TEXT[] NOT NULL DEFAULT ARRAY['*']::text[],
    aggregates      TEXT[] NOT NULL DEFAULT ARRAY['*']::text[],
    active          BOOLEAN NOT NULL DEFAULT true,
    headers         JSONB NOT NULL DEFAULT '{}'::jsonb,
    max_attempts    INT NOT NULL DEFAULT 8,
    timeout_ms      INT NOT NULL DEFAULT 5000,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
  );

  CREATE INDEX IF NOT EXISTS webhook_subs_tenant_idx
    ON public.webhook_subscriptions (tenant_id, active);

  ALTER TABLE public.webhook_subscriptions ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'webhook_subscriptions'
         AND policyname = 'webhook_subs_tenant_isolation'
    ) THEN
      CREATE POLICY webhook_subs_tenant_isolation ON public.webhook_subscriptions
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  CREATE TABLE IF NOT EXISTS public.webhook_deliveries (
    id              BIGSERIAL PRIMARY KEY,
    subscription_id UUID NOT NULL REFERENCES public.webhook_subscriptions(id) ON DELETE CASCADE,
    tenant_id       TEXT NOT NULL,
    event_id        TEXT NOT NULL,
    aggregate       TEXT NOT NULL,
    event_type      TEXT NOT NULL,
    payload         JSONB NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','success','failed','dead')),
    attempts        INT NOT NULL DEFAULT 0,
    last_error      TEXT,
    last_status_code INT,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (subscription_id, event_id)
  );

  CREATE INDEX IF NOT EXISTS webhook_deliv_pending_idx
    ON public.webhook_deliveries (status, next_attempt_at)
    WHERE status = 'pending';

  CREATE INDEX IF NOT EXISTS webhook_deliv_tenant_idx
    ON public.webhook_deliveries (tenant_id, created_at DESC);

  ALTER TABLE public.webhook_deliveries ENABLE ROW LEVEL SECURITY;

  DO $pol2$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'webhook_deliveries'
         AND policyname = 'webhook_deliv_tenant_isolation'
    ) THEN
      CREATE POLICY webhook_deliv_tenant_isolation ON public.webhook_deliveries
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol2$;

  GRANT SELECT, INSERT, UPDATE, DELETE ON public.webhook_subscriptions TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE ON public.webhook_deliveries TO authenticated, service_role;
  GRANT USAGE, SELECT ON SEQUENCE public.webhook_deliveries_id_seq TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (31, '031_webhooks')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.webhook_deliveries;
-- DROP TABLE IF EXISTS public.webhook_subscriptions;
-- DELETE FROM public.schema_migrations WHERE version = 31;
-- COMMIT;
