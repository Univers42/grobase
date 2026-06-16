# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    014_add_http_engine.sql                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 23:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 23:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/014_add_http_engine.sql
-- Migration 014 (M2 federation): extend tenant_databases.engine CHECK to
-- accept the new 'http' adapter introduced by HttpEngine. The other engines
-- (mysql, redis) were already in the CHECK from migration 004 — only 'http'
-- is new.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 14) THEN
    RAISE NOTICE 'Migration 014 already applied — skipping';
    RETURN;
  END IF;

  -- The original constraint name from migration 004.
  ALTER TABLE public.tenant_databases
    DROP CONSTRAINT IF EXISTS tenant_databases_engine_check;

  ALTER TABLE public.tenant_databases
    ADD CONSTRAINT tenant_databases_engine_check
    CHECK (engine IN ('postgresql', 'mongodb', 'mysql', 'redis', 'sqlite', 'http'));

  INSERT INTO public.schema_migrations (version, name)
  VALUES (14, '014_add_http_engine')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- ALTER TABLE public.tenant_databases DROP CONSTRAINT tenant_databases_engine_check;
-- ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_engine_check
--   CHECK (engine IN ('postgresql','mongodb','mysql','redis','sqlite'));
-- DELETE FROM public.schema_migrations WHERE version = 14;
-- COMMIT;
