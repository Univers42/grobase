-- ****************************************************************************
--
--                                                         :::      ::::::::
--    069_add_dynamodb_engine_check.sql                  :+:      :+:    :+:
--                                                     +:+ +:+         +:+
--    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+
--                                                 +#+#+#+#+#+   +#+
--    Created: 2026/06/19 00:00:00 by dlesieur          #+#    #+#
--    Updated: 2026/06/19 00:00:00 by dlesieur         ###   ########.fr
--
-- ****************************************************************************

-- File: scripts/migrations/postgresql/069_add_dynamodb_engine_check.sql
-- Allow the 8th engine (DynamoDB) in tenant_databases.engine. The Go control
-- plane still gates acceptance behind DYNAMODB_ENGINE_ENABLED (isAllowedEngine),
-- and the data plane must be built --features dynamodb to serve it; this only
-- removes the DB CHECK that rejected the row outright. Mirrors 021.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 69) THEN
    RAISE NOTICE 'Migration 069 already applied - skipping';
    RETURN;
  END IF;

  ALTER TABLE public.tenant_databases
    DROP CONSTRAINT IF EXISTS tenant_databases_engine_check;

  ALTER TABLE public.tenant_databases
    ADD CONSTRAINT tenant_databases_engine_check
    CHECK (engine IN (
      'postgresql', 'cockroachdb', 'mongodb', 'mysql', 'mariadb', 'redis',
      'sqlite', 'mssql', 'http', 'dynamodb',
      'jdbc', 'cassandra', 'neo4j', 'elasticsearch', 'qdrant', 'influx'
    ));

  INSERT INTO public.schema_migrations (version, name)
  VALUES (69, '069_add_dynamodb_engine_check')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;
