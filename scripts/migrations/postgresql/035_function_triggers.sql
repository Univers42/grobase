-- File: scripts/migrations/postgresql/035_function_triggers.sql
-- Migration 035: DB-event -> function triggers (A2 Functions DX).
--
-- A function_trigger subscribes an edge function (deployed on the
-- functions-runtime) to outbox events (orders.created, etc.). When an outbox
-- event matches an enabled trigger, the webhook-dispatcher invokes the function
-- (POST /v1/functions/<name>/invoke) with the change payload instead of POSTing
-- an external URL. It reuses the SAME delivery ledger (webhook_deliveries) +
-- retry/DLQ machinery as webhook_subscriptions.
--
-- Mirrors the RLS + idempotency pattern of 031_webhooks.sql. Owned by the
-- webhook-dispatcher (Go service); rows are tenant-scoped via RLS.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 35) THEN
    RAISE NOTICE 'Migration 035 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.function_triggers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT NOT NULL,
    name            TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
    -- The deployed function to invoke (matches the runtime's name rules:
    -- [a-zA-Z][a-zA-Z0-9_-]{0,63}). Stored verbatim and re-validated in Go.
    function_name   TEXT NOT NULL CHECK (function_name ~ '^[a-zA-Z][a-zA-Z0-9_-]{0,63}$'),
    -- Same shape as webhook_subscriptions: '*' wildcards match everything.
    event_types     TEXT[] NOT NULL DEFAULT ARRAY['*']::text[],
    aggregates      TEXT[] NOT NULL DEFAULT ARRAY['*']::text[],
    enabled         BOOLEAN NOT NULL DEFAULT true,
    max_attempts    INT NOT NULL DEFAULT 8,
    timeout_ms      INT NOT NULL DEFAULT 5000,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
  );

  CREATE INDEX IF NOT EXISTS function_triggers_tenant_idx
    ON public.function_triggers (tenant_id, enabled);

  ALTER TABLE public.function_triggers ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'function_triggers'
         AND policyname = 'function_triggers_tenant_isolation'
    ) THEN
      CREATE POLICY function_triggers_tenant_isolation ON public.function_triggers
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- function_deliveries reuses the EXACT shape of webhook_deliveries so the
  -- dispatcher's retry/DLQ scan can treat both uniformly. trigger_id replaces
  -- subscription_id; everything else is identical.
  CREATE TABLE IF NOT EXISTS public.function_deliveries (
    id              BIGSERIAL PRIMARY KEY,
    trigger_id      UUID NOT NULL REFERENCES public.function_triggers(id) ON DELETE CASCADE,
    tenant_id       TEXT NOT NULL,
    function_name   TEXT NOT NULL,
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
    UNIQUE (trigger_id, event_id)
  );

  CREATE INDEX IF NOT EXISTS function_deliv_pending_idx
    ON public.function_deliveries (status, next_attempt_at)
    WHERE status = 'pending';

  CREATE INDEX IF NOT EXISTS function_deliv_tenant_idx
    ON public.function_deliveries (tenant_id, created_at DESC);

  ALTER TABLE public.function_deliveries ENABLE ROW LEVEL SECURITY;

  DO $pol2$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'function_deliveries'
         AND policyname = 'function_deliv_tenant_isolation'
    ) THEN
      CREATE POLICY function_deliv_tenant_isolation ON public.function_deliveries
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol2$;

  GRANT SELECT, INSERT, UPDATE, DELETE ON public.function_triggers TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE ON public.function_deliveries TO authenticated, service_role;
  GRANT USAGE, SELECT ON SEQUENCE public.function_deliveries_id_seq TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (35, '035_function_triggers')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.function_deliveries;
-- DROP TABLE IF EXISTS public.function_triggers;
-- DELETE FROM public.schema_migrations WHERE version = 35;
-- COMMIT;
