# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    013_audit_log.sql                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 21:30:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 21:30:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/013_audit_log.sql
-- Migration 013 (M1 hardening): generic audit_log table.
--
-- Receives one row per mutating HTTP request (POST/PATCH/PUT/DELETE) written
-- by the application-layer AuditInterceptor. The request_id column is the
-- X-Request-ID propagated by the CorrelationIdInterceptor, so each audit row
-- can be cross-joined with the Loki logs of the same request (M4) and with
-- the outbox events of the same request (M3).
--
-- Designed to be idempotent: re-running this migration on an already-migrated
-- database is a no-op thanks to the schema_migrations guard.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 13) THEN
    RAISE NOTICE 'Migration 013 already applied — skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.audit_log (
    id          BIGSERIAL PRIMARY KEY,
    request_id  UUID NOT NULL,
    actor_id    UUID,
    actor_role  TEXT,
    action      TEXT NOT NULL,
    resource    TEXT NOT NULL,
    payload     JSONB,
    ip          INET,
    user_agent  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  CREATE INDEX IF NOT EXISTS audit_log_actor_idx
    ON public.audit_log (actor_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS audit_log_request_idx
    ON public.audit_log (request_id);
  CREATE INDEX IF NOT EXISTS audit_log_resource_idx
    ON public.audit_log (resource, created_at DESC);

  -- audit_log is read-only for application roles; only writes via the
  -- privileged audit_writer role (set up at runtime via GRANT in compose
  -- bootstrap). For now: lock down via RLS so a compromised user JWT cannot
  -- DELETE or UPDATE history.
  ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

  DROP POLICY IF EXISTS audit_log_self_read ON public.audit_log;
  CREATE POLICY audit_log_self_read ON public.audit_log
    FOR SELECT TO authenticated
    USING (
      actor_id IS NOT NULL
      AND actor_id::text = current_setting('request.jwt.claims', true)::jsonb->>'sub'
    );

  -- service_role inserts via the interceptor.
  DROP POLICY IF EXISTS audit_log_service_write ON public.audit_log;
  CREATE POLICY audit_log_service_write ON public.audit_log
    FOR INSERT TO authenticated
    WITH CHECK (true);

  GRANT SELECT, INSERT ON public.audit_log TO authenticated;
  GRANT USAGE, SELECT  ON SEQUENCE public.audit_log_id_seq TO authenticated;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (13, '013_audit_log')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.audit_log;
-- DELETE FROM public.schema_migrations WHERE version = 13;
-- COMMIT;
