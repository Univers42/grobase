-- ****************************************************************************
--                                                                              
--                                                         :::      ::::::::    
--    020_fdw_servers.sql                               :+:      :+:    :+:    
--                                                     +:+ +:+         +:+      
--    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         
--                                                 +#+#+#+#+#+   +#+            
--    Created: 2026/05/31 21:10:00 by dlesieur          #+#    #+#              
--    Updated: 2026/05/31 21:10:00 by dlesieur         ###   ########.fr        
--                                                                              
-- ****************************************************************************

-- File: scripts/migrations/postgresql/020_fdw_servers.sql
-- M6: FDW universal gateway. Installs every FDW that is present in the image
-- and exposes guarded helpers used by adapter-registry to materialize external
-- resources behind PostgREST/RLS.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 20) THEN
    RAISE NOTICE 'Migration 020 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.fdw_external_resources (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL,
    database_id     UUID REFERENCES public.tenant_databases(id) ON DELETE CASCADE,
    engine          TEXT NOT NULL,
    server_name     TEXT NOT NULL,
    foreign_schema  TEXT NOT NULL DEFAULT 'fdw',
    foreign_table   TEXT NOT NULL,
    source_options  JSONB NOT NULL DEFAULT '{}'::jsonb,
    columns         JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, foreign_schema, foreign_table)
  );

  ALTER TABLE public.fdw_external_resources ENABLE ROW LEVEL SECURITY;

  DROP POLICY IF EXISTS fdw_external_resources_tenant ON public.fdw_external_resources;
  CREATE POLICY fdw_external_resources_tenant ON public.fdw_external_resources
    FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
    WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);

  GRANT SELECT, INSERT, UPDATE, DELETE ON public.fdw_external_resources TO authenticated, service_role;
END $$;

CREATE OR REPLACE FUNCTION public.ensure_fdw_extension(p_extension TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = p_extension) THEN
    EXECUTE format('CREATE EXTENSION IF NOT EXISTS %I', p_extension);
    RETURN true;
  END IF;
  RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.fdws_bootstrap_available()
RETURNS TABLE(extension_name TEXT, installed BOOLEAN) AS $$
DECLARE
  ext TEXT;
  extensions CONSTANT TEXT[] := ARRAY[
    'mysql_fdw',
    'mongo_fdw',
    'tds_fdw',
    'oracle_fdw',
    'redis_fdw',
    'clickhousedb_fdw',
    'multicorn',
    'file_fdw',
    'sqlite_fdw'
  ];
BEGIN
  FOREACH ext IN ARRAY extensions LOOP
    extension_name := ext;
    installed := public.ensure_fdw_extension(ext);
    RETURN NEXT;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.fdw_extension_for_engine(p_engine TEXT)
RETURNS TEXT AS $$
BEGIN
  RETURN CASE p_engine
    WHEN 'mysql' THEN 'mysql_fdw'
    WHEN 'mssql' THEN 'tds_fdw'
    WHEN 'mongodb' THEN 'mongo_fdw'
    WHEN 'mongo' THEN 'mongo_fdw'
    WHEN 'oracle' THEN 'oracle_fdw'
    WHEN 'redis' THEN 'redis_fdw'
    WHEN 'elasticsearch' THEN 'multicorn'
    WHEN 'es' THEN 'multicorn'
    WHEN 'clickhouse' THEN 'clickhousedb_fdw'
    WHEN 'sqlite' THEN 'sqlite_fdw'
    WHEN 'csv' THEN 'file_fdw'
    WHEN 'http' THEN 'multicorn'
    ELSE NULL
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION public.options_clause(p_options JSONB)
RETURNS TEXT AS $$
  SELECT string_agg(format('%I %L', key, value), ', ' ORDER BY key)
  FROM jsonb_each_text(COALESCE(p_options, '{}'::jsonb));
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.materialize_fdw_server(
  p_engine TEXT,
  p_server_name TEXT,
  p_options JSONB DEFAULT '{}'::jsonb
) RETURNS TEXT AS $$
DECLARE
  fdw_name TEXT := public.fdw_extension_for_engine(p_engine);
  options_sql TEXT := public.options_clause(p_options);
BEGIN
  IF fdw_name IS NULL THEN
    RAISE EXCEPTION 'No FDW mapping for engine %', p_engine;
  END IF;
  IF NOT public.ensure_fdw_extension(fdw_name) THEN
    RAISE EXCEPTION 'FDW extension % is not installed in this Postgres image', fdw_name;
  END IF;
  IF options_sql IS NULL OR options_sql = '' THEN
    EXECUTE format('CREATE SERVER IF NOT EXISTS %I FOREIGN DATA WRAPPER %I', p_server_name, fdw_name);
  ELSE
    EXECUTE format('CREATE SERVER IF NOT EXISTS %I FOREIGN DATA WRAPPER %I OPTIONS (%s)', p_server_name, fdw_name, options_sql);
  END IF;
  RETURN p_server_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.register_fdw_foreign_table(
  p_tenant_id UUID,
  p_database_id UUID,
  p_engine TEXT,
  p_server_name TEXT,
  p_foreign_schema TEXT,
  p_foreign_table TEXT,
  p_options JSONB DEFAULT '{}'::jsonb,
  p_columns JSONB DEFAULT '[]'::jsonb
) RETURNS TEXT AS $$
DECLARE
  alias_name TEXT := p_foreign_schema || '.' || p_foreign_table;
BEGIN
  IF p_foreign_schema !~ '^[a-zA-Z_]\w{0,63}$' OR p_foreign_table !~ '^[a-zA-Z_]\w{0,63}$' THEN
    RAISE EXCEPTION 'Invalid FDW schema/table alias %.%', p_foreign_schema, p_foreign_table;
  END IF;

  INSERT INTO public.fdw_external_resources (
    tenant_id,
    database_id,
    engine,
    server_name,
    foreign_schema,
    foreign_table,
    source_options,
    columns
  ) VALUES (
    p_tenant_id,
    p_database_id,
    p_engine,
    p_server_name,
    p_foreign_schema,
    p_foreign_table,
    COALESCE(p_options, '{}'::jsonb),
    COALESCE(p_columns, '[]'::jsonb)
  )
  ON CONFLICT (tenant_id, foreign_schema, foreign_table)
  DO UPDATE SET
    database_id = EXCLUDED.database_id,
    engine = EXCLUDED.engine,
    server_name = EXCLUDED.server_name,
    source_options = EXCLUDED.source_options,
    columns = EXCLUDED.columns;

  RETURN alias_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ===========================================================================
-- @brief Lock down the SECURITY DEFINER FDW helpers (privilege-management fix).
--
-- @par Vulnerability (CWE-269 Improper Privilege Management)
--   ensure_fdw_extension / fdws_bootstrap_available / materialize_fdw_server /
--   register_fdw_foreign_table are SECURITY DEFINER and owned by the `postgres`
--   superuser (migrations run as `psql -U postgres`), so their bodies execute
--   with superuser rights — running CREATE EXTENSION / CREATE SERVER DDL and
--   RLS-bypassing INSERTs. PostgreSQL grants EXECUTE to PUBLIC on every new
--   function by default, and PostgREST is published over `public` with
--   `PGRST_DB_ANON_ROLE=anon`, so each function was reachable as
--   POST /rpc/<fn> by the anon/authenticated roles. A low-privilege HTTP caller
--   could thus install any FDW shipped in the image and create foreign-data
--   servers as superuser — a privilege-escalation stepping stone to
--   exfiltration/RCE. Migration 065 hardened TABLE grants but left FUNCTION
--   EXECUTE untouched, so this gap survived it.
--
-- @par Remediation
--   REVOKE EXECUTE FROM PUBLIC (and explicitly from anon, authenticated) on the
--   four privileged functions, GRANT EXECUTE only to service_role (the control
--   plane / adapter-registry path; the postgres owner keeps access inherently),
--   and pin each function's search_path so it cannot be hijacked via a
--   caller-controlled schema. This block is idempotent and — because the
--   migrate runner re-applies every file — repairs already-migrated databases
--   on the next `make migrate`.
--
-- @see https://www.postgresql.org/docs/current/sql-createfunction.html#SQL-CREATEFUNCTION-SECURITY
-- @see https://cwe.mitre.org/data/definitions/269.html
-- ===========================================================================
REVOKE EXECUTE ON FUNCTION
  public.ensure_fdw_extension(text),
  public.fdws_bootstrap_available(),
  public.materialize_fdw_server(text, text, jsonb),
  public.register_fdw_foreign_table(uuid, uuid, text, text, text, text, jsonb, jsonb)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.ensure_fdw_extension(text),
  public.fdws_bootstrap_available(),
  public.materialize_fdw_server(text, text, jsonb),
  public.register_fdw_foreign_table(uuid, uuid, text, text, text, text, jsonb, jsonb)
TO service_role;

ALTER FUNCTION public.ensure_fdw_extension(text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.fdws_bootstrap_available()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.materialize_fdw_server(text, text, jsonb)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.register_fdw_foreign_table(uuid, uuid, text, text, text, text, jsonb, jsonb)
  SET search_path = pg_catalog, public, pg_temp;

SELECT * FROM public.fdws_bootstrap_available();

INSERT INTO public.schema_migrations (version, name)
VALUES (20, '020_fdw_servers')
ON CONFLICT (version) DO NOTHING;

COMMIT;