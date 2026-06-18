# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    039_internal_table_hardening.sql                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Migration 039 — lock down internal/system tables that carry cross-tenant data
# but have no RLS, so they can never be read by the public PostgREST roles.
#
# FOUND BY the v1.1.0 GraphQL adversarial review (A5):
#   001_initial_schema.sql blanket-grants SELECT/INSERT/UPDATE/DELETE to `anon`
#   and `authenticated` on ALL public tables + ALTER DEFAULT PRIVILEGES, so every
#   table created later silently inherits an anon grant. Two public tables have
#   NO row-level security (every other public table does):
#     - public.outbox_events    -> the transactional CDC ledger: every tenant's
#                                  row mutations + actor_id + request_id.
#     - public.schema_migrations -> the applied-migration version list.
#   In the GraphQL edition (pg_graphql + PGRST_DB_SCHEMAS includes graphql_public)
#   pg_graphql exposes any PK table the caller's role can read, so an
#   UNAUTHENTICATED anon caller could `{ outboxEventsCollection { … payload } }`
#   and read every tenant's change payloads. This also closes the same anon-read
#   over the REST surface.
#
# SAFE for the producers/consumers: the data plane writes the outbox as the
# `postgres` superuser (DATA_PLANE_OUTBOX_DSN) and the outbox relay reads/marks
# it as `postgres` + `service_role` (BYPASSRLS) — all of which bypass RLS and
# keep their grants. Only anon/authenticated lose access.

-- 1) Revoke the inherited blanket grants on both internal tables.
REVOKE ALL ON public.outbox_events     FROM anon, authenticated;
REVOKE ALL ON public.schema_migrations FROM anon, authenticated;

-- 2) Deny-all RLS on the outbox ledger as a backstop: even if a future
--    default-privilege grant re-adds anon SELECT, no policy = no rows for any
--    non-owner, non-superuser, non-BYPASSRLS role. The producer (postgres
--    superuser) and relay (service_role BYPASSRLS) are unaffected.
ALTER TABLE public.outbox_events ENABLE ROW LEVEL SECURITY;
-- re-affirm the legitimate consumer grant (service_role is BYPASSRLS anyway).
GRANT SELECT, INSERT, UPDATE ON public.outbox_events TO service_role;

-- 3) Durable fix for the 012 event-trigger re-arm (review L1): migration 012
--    installs realtime_auto_trigger_on_create (ddl_command_end EVENT TRIGGER)
--    that attaches a realtime trigger to ANY new public table via
--    realtime_ensure_trigger(). Migration 038 dropped the realtime trigger on
--    outbox_events, but if the table is ever recreated the event trigger would
--    re-arm it (the >8KB pg_notify wedge returns). Redefine the helper to SKIP
--    internal tables, so the drop can never be re-armed at the source.
CREATE OR REPLACE FUNCTION public.realtime_ensure_trigger(
  _schema TEXT,
  _table  TEXT
) RETURNS VOID AS $fn$
DECLARE
  _trigger_name TEXT := _table || '_realtime_trigger';
BEGIN
  -- Internal/system tables are NOT user data and must never carry a realtime
  -- trigger (outbox_events.pg_notify on the relay's markPublished UPDATE wedges
  -- the relay on >8KB payloads; schema_migrations is bookkeeping).
  IF _schema = 'public' AND _table IN ('outbox_events', 'schema_migrations') THEN
    RETURN;
  END IF;

  -- Skip if the trigger already exists
  IF EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE event_object_schema = _schema
      AND event_object_table  = _table
      AND trigger_name        = _trigger_name
  ) THEN
    RETURN;
  END IF;

  EXECUTE format(
    'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION public.realtime_notify()',
    _trigger_name, _schema, _table
  );

  RAISE NOTICE 'realtime trigger installed on %.%', _schema, _table;
END;
$fn$ LANGUAGE plpgsql;

-- Belt-and-suspenders: ensure the ledger trigger is gone even if 038 ordering
-- ever changed (idempotent).
DROP TRIGGER IF EXISTS outbox_events_realtime_trigger ON public.outbox_events;
