-- File: scripts/migrations/postgresql/036_function_schedules.sql
-- Migration 036: scheduled (cron) function invocation (A2 Functions DX).
--
-- A function_schedule fires a deployed edge function on an interval. The
-- function-scheduler binary polls due schedules and invokes them on the
-- functions-runtime. The schedule expression is a minimal, zero-dep grammar
-- (no external cron lib is available in go.mod offline):
--   "@every 30s" | "@every 5m" | "@every 1h"   (interval)
--   "@hourly" | "@daily"                        (aliases)
--   "30" / "30s" / "5m" / "1h"                  (bare interval, seconds default)
-- Parsing + next-run math live in Go (internal/scheduler) and are unit-tested.
--
-- Mirrors the RLS + idempotency pattern of 031/035. Owned by the
-- function-scheduler (Go service); rows are tenant-scoped via RLS.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 36) THEN
    RAISE NOTICE 'Migration 036 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.function_schedules (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT NOT NULL,
    name            TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
    function_name   TEXT NOT NULL CHECK (function_name ~ '^[a-zA-Z][a-zA-Z0-9_-]{0,63}$'),
    -- Schedule expression (see grammar above). Re-validated + parsed in Go.
    schedule_expr   TEXT NOT NULL CHECK (char_length(schedule_expr) BETWEEN 1 AND 64),
    -- Optional JSON payload handed to the function as the invoke body.
    payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
    enabled         BOOLEAN NOT NULL DEFAULT true,
    timeout_ms      INT NOT NULL DEFAULT 5000,
    last_run        TIMESTAMPTZ,
    next_run        TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_status     TEXT,
    last_error      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
  );

  -- The scheduler scans for due rows; index on (enabled, next_run).
  CREATE INDEX IF NOT EXISTS function_schedules_due_idx
    ON public.function_schedules (enabled, next_run)
    WHERE enabled = true;

  ALTER TABLE public.function_schedules ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'function_schedules'
         AND policyname = 'function_schedules_tenant_isolation'
    ) THEN
      CREATE POLICY function_schedules_tenant_isolation ON public.function_schedules
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  GRANT SELECT, INSERT, UPDATE, DELETE ON public.function_schedules TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (36, '036_function_schedules')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.function_schedules;
-- DELETE FROM public.schema_migrations WHERE version = 36;
-- COMMIT;
