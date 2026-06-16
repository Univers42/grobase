# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    015_outbox_events.sql                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 15:20:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 16:38:11 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/015_outbox_events.sql
-- Migration 015 (M3 coherence): transactional outbox for cross-engine events.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 15) THEN
    RAISE NOTICE 'Migration 015 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.outbox_events (
    id            BIGSERIAL PRIMARY KEY,
    aggregate     TEXT NOT NULL,
    aggregate_id  TEXT NOT NULL,
    event_type    TEXT NOT NULL,
    payload       JSONB NOT NULL,
    request_id    UUID,
    actor_id      UUID,
    status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'published', 'failed', 'dead')),
    attempts      INT NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at  TIMESTAMPTZ,
    last_error    TEXT
  );

  CREATE INDEX IF NOT EXISTS outbox_pending_idx
    ON public.outbox_events (status, created_at)
    WHERE status = 'pending';

  CREATE INDEX IF NOT EXISTS outbox_aggregate_idx
    ON public.outbox_events (aggregate, aggregate_id, created_at DESC);

  GRANT SELECT, INSERT, UPDATE ON public.outbox_events TO authenticated, service_role;
  GRANT USAGE, SELECT ON SEQUENCE public.outbox_events_id_seq TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (15, '015_outbox_events')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.outbox_events;
-- DELETE FROM public.schema_migrations WHERE version = 15;
-- COMMIT;