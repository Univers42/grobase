-- ****************************************************************************
--                                                                              
--                                                         :::      ::::::::    
--    021_extend_engine_check.sql                       :+:      :+:    :+:    
--                                                     +:+ +:+         +:+      
--    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         
--                                                 +#+#+#+#+#+   +#+            
--    Created: 2026/05/31 21:20:00 by dlesieur          #+#    #+#              
--    Updated: 2026/05/31 21:20:00 by dlesieur         ###   ########.fr        
--                                                                              
-- ****************************************************************************

-- File: scripts/migrations/postgresql/021_extend_engine_check.sql
-- M7: allow the new agnostic adapters in tenant_databases.engine.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 21) THEN
    RAISE NOTICE 'Migration 021 already applied - skipping';
    RETURN;
  END IF;

  ALTER TABLE public.tenant_databases
    DROP CONSTRAINT IF EXISTS tenant_databases_engine_check;

  ALTER TABLE public.tenant_databases
    ADD CONSTRAINT tenant_databases_engine_check
    CHECK (engine IN (
      'postgresql', 'mongodb', 'mysql', 'redis', 'sqlite', 'http',
      'jdbc', 'cassandra', 'neo4j', 'elasticsearch', 'qdrant', 'influx'
    ));

  INSERT INTO public.schema_migrations (version, name)
  VALUES (21, '021_extend_engine_check')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;