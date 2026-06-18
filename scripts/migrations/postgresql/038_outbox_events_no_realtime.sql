# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    038_outbox_events_no_realtime.sql                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/038_outbox_events_no_realtime.sql
-- Migration: stop the outbox relay from wedging on its own ledger updates.
-- UP
--
-- BUG (found by the m56 functions-live gate): 012_realtime_triggers_all_tables
-- blanket-installed `<table>_realtime_trigger` on EVERY public table — including
-- public.outbox_events, which is an INTERNAL relay ledger, not a user data
-- table. The trigger calls pg_notify() with the row payload on every write.
--
-- The outbox relay marks each delivered event published with an UPDATE on
-- outbox_events. That UPDATE re-fires the realtime trigger, which pg_notify()s
-- the event's payload. For events whose payload exceeds Postgres' hard 8000-byte
-- NOTIFY limit, the UPDATE fails with SQLSTATE 22023 ("payload string too
-- long") — so markPublished() fails, the event is never marked published, and
-- the relay retries it forever. One oversized event stalls the whole relay
-- (observed: 14k+ events stuck `pending`, function triggers + tenant-scoped
-- webhooks never delivered).
--
-- outbox_events feeds the relay (Redis Streams) and the dispatchers directly;
-- nothing subscribes to it over the realtime CDC channel. It must NOT carry a
-- realtime trigger. Drop it (idempotent).

DROP TRIGGER IF EXISTS outbox_events_realtime_trigger ON public.outbox_events;

-- DOWN
-- (intentionally not recreated — a realtime trigger on the relay ledger is a bug)
