# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    086_realtime_notify_payload_cap.sql               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/29 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/29 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/086_realtime_notify_payload_cap.sql
-- Migration 086: cap the realtime_notify() NOTIFY payload at the Postgres limit.
--
-- realtime_notify() (011/012) builds a NOTIFY payload from the ENTIRE changed
-- row (row_to_json(NEW) + row_to_json(OLD)). Postgres caps a pg_notify payload
-- at 8000 bytes, so any large row (e.g. a big osionos_pages.content) raised
-- SQLSTATE 22023 "payload string too long" and ABORTED THE WRITE — a real
-- data-loss-shaped bug for any table carrying the generic realtime trigger.
--
-- This redefines the function to detect an oversized payload and instead emit a
-- lightweight signal (table/schema/operation + the row id + truncated:true) so
-- the write always succeeds; realtime consumers refetch on a truncated event.
-- Engine-agnostic at the SQL layer; applies to every table with the trigger.

BEGIN;

CREATE OR REPLACE FUNCTION public.realtime_notify()
RETURNS TRIGGER AS $fn$
DECLARE
  payload JSON;
BEGIN
  payload := json_build_object(
    'table',     TG_TABLE_NAME,
    'schema',    TG_TABLE_SCHEMA,
    'operation', TG_OP,
    'data',      CASE
                   WHEN TG_OP = 'DELETE' THEN row_to_json(OLD)
                   ELSE row_to_json(NEW)
                 END,
    'old_data',  CASE
                   WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD)
                   ELSE NULL
                 END
  );

  IF octet_length(payload::text) > 7900 THEN
    payload := json_build_object(
      'table',     TG_TABLE_NAME,
      'schema',    TG_TABLE_SCHEMA,
      'operation', TG_OP,
      'data',      json_build_object(
                     'id', CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD)->>'id' ELSE to_jsonb(NEW)->>'id' END
                   ),
      'truncated', true
    );
  END IF;

  PERFORM pg_notify('realtime_events', payload::text);
  RETURN COALESCE(NEW, OLD);
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 86) THEN
    RAISE NOTICE 'Migration 086 already applied — skipping';
    RETURN;
  END IF;
  INSERT INTO public.schema_migrations (version, name) VALUES (86, '086_realtime_notify_payload_cap');
END $$;

COMMIT;
