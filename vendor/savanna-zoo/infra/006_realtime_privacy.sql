-- ============================================================
-- 006_realtime_privacy.sql — stop realtime broadcast of non-public rows.
--
-- Threat fixed (realtime PII leak): Grobase's realtime plane installs a
-- <table>_realtime_trigger on every public table that pg_notify's the FULL ROW
-- to the gateway, which fans it out to ANY authenticated subscriber WITHOUT
-- owner-scoping or role-gating. So a plain visitor can
--   SUBSCRIBE pg/tickets/inserted
-- and receive every other visitor's booking (name, email, qr, user_id) live —
-- even though PostgREST RLS hides those rows from a REST read. (Verified live:
-- a visitor harvested a victim's ticket email over the WS.)
--
-- The proper fix is owner-scoped fan-out in the realtime gateway (platform
-- work). Until then, the app-level mitigation is: only publish realtime for
-- tables that are PUBLIC by RLS anyway (SELECT USING(true): animals, events,
-- staff, ticket_types, visitor_stats) and DROP the publish trigger on every
-- table whose rows are not public. Cost: the admin grids for tickets/messages/
-- feeding lose live auto-update and fall back to fetch-on-load — an acceptable
-- trade for not leaking visitor PII. The auto-install event trigger only fires
-- on CREATE TABLE, so these drops are permanent for the existing tables.
-- ============================================================
SET search_path TO public;

DROP TRIGGER IF EXISTS tickets_realtime_trigger          ON tickets;
DROP TRIGGER IF EXISTS visitor_messages_realtime_trigger ON visitor_messages;
DROP TRIGGER IF EXISTS health_records_realtime_trigger   ON health_records;
DROP TRIGGER IF EXISTS feeding_logs_realtime_trigger     ON feeding_logs;
DROP TRIGGER IF EXISTS zoo_audit_log_realtime_trigger    ON zoo_audit_log;
