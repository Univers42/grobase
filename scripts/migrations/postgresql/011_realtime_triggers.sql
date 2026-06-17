# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    011_realtime_triggers.sql                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/011_realtime_triggers.sql
-- Migration 011: Realtime CDC triggers for realtime-agnostic engine
--
-- The Rust realtime engine LISTENs on the `realtime_events` channel.
-- This migration creates the trigger function that NOTIFYs on every
-- row change and attaches it to the generic BaaS tables.
--
-- Consuming applications should add their own triggers for domain tables:
--
--   CREATE TRIGGER my_table_realtime_trigger
--     AFTER INSERT OR UPDATE OR DELETE ON public.my_table
--     FOR EACH ROW EXECUTE FUNCTION public.realtime_notify();

BEGIN;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 11) THEN
    RAISE NOTICE 'Migration 011 already applied — skipping';
    RETURN;
  END IF;

  -- ══════════════════════════════════════════════════════════════════
  -- 1. Trigger function: pg_notify on the `realtime_events` channel
  --    The realtime-agnostic engine auto-creates this function at
  --    startup, but we declare it here so migrations are self-contained
  --    and triggers work even if the engine hasn't started yet.
  -- ══════════════════════════════════════════════════════════════════
  CREATE OR REPLACE FUNCTION public.realtime_notify()
  RETURNS TRIGGER AS $fn$
  DECLARE
    payload JSONB;
  BEGIN
    payload := jsonb_build_object(
      'schema',     TG_TABLE_SCHEMA,
      'table',      TG_TABLE_NAME,
      'type',       TG_OP,
      'record',     CASE
                      WHEN TG_OP = 'DELETE' THEN row_to_json(OLD)::jsonb
                      ELSE row_to_json(NEW)::jsonb
                    END,
      'old_record', CASE
                      WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD)::jsonb
                      ELSE NULL
                    END,
      'timestamp',  extract(epoch FROM now())
    );

    PERFORM pg_notify('realtime_events', payload::text);
    RETURN COALESCE(NEW, OLD);
  END;
  $fn$ LANGUAGE plpgsql SECURITY DEFINER;

  -- ══════════════════════════════════════════════════════════════════
  -- 2. Attach triggers to generic BaaS tables
  -- ══════════════════════════════════════════════════════════════════

  -- posts (content collaboration)
  DROP TRIGGER IF EXISTS posts_realtime_trigger ON public.posts;
  CREATE TRIGGER posts_realtime_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public.realtime_notify();

  -- mock_orders (order status tracking)
  DROP TRIGGER IF EXISTS mock_orders_realtime_trigger ON public.mock_orders;
  CREATE TRIGGER mock_orders_realtime_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.mock_orders
    FOR EACH ROW EXECUTE FUNCTION public.realtime_notify();

  -- user_presence (online/offline status)
  DROP TRIGGER IF EXISTS user_presence_realtime_trigger ON public.user_presence;
  CREATE TRIGGER user_presence_realtime_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.user_presence
    FOR EACH ROW EXECUTE FUNCTION public.realtime_notify();

  -- friendships (social interactions)
  DROP TRIGGER IF EXISTS friendships_realtime_trigger ON public.friendships;
  CREATE TRIGGER friendships_realtime_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.friendships
    FOR EACH ROW EXECUTE FUNCTION public.realtime_notify();

  -- user_profiles (profile changes)
  DROP TRIGGER IF EXISTS user_profiles_realtime_trigger ON public.user_profiles;
  CREATE TRIGGER user_profiles_realtime_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.user_profiles
    FOR EACH ROW EXECUTE FUNCTION public.realtime_notify();

  -- Record migration
  INSERT INTO public.schema_migrations (version, name) VALUES (11, '011_realtime_triggers');

END $$;

COMMIT;

-- DOWN (rollback)
-- DROP TRIGGER IF EXISTS posts_realtime_trigger ON public.posts;
-- DROP TRIGGER IF EXISTS mock_orders_realtime_trigger ON public.mock_orders;
-- DROP TRIGGER IF EXISTS user_presence_realtime_trigger ON public.user_presence;
-- DROP TRIGGER IF EXISTS friendships_realtime_trigger ON public.friendships;
-- DROP TRIGGER IF EXISTS user_profiles_realtime_trigger ON public.user_profiles;
-- DROP FUNCTION IF EXISTS public.realtime_notify();
-- DELETE FROM schema_migrations WHERE version = 11;
