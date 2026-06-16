CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS auth;

ALTER ROLE postgres IN DATABASE postgres SET search_path = auth, public;

SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') AS anon_role_exists
\gset

\if :anon_role_exists
\else
CREATE ROLE anon NOLOGIN;
\endif

SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AS authenticated_role_exists
\gset

\if :authenticated_role_exists
\else
CREATE ROLE authenticated NOLOGIN;
\endif

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;

SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') AS service_role_exists
\gset

\if :service_role_exists
ALTER ROLE service_role BYPASSRLS;
\else
CREATE ROLE service_role NOLOGIN BYPASSRLS;
\endif

GRANT USAGE ON SCHEMA public TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;

SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') AS role_exists
\gset

\if :role_exists
ALTER ROLE supabase_admin
  WITH LOGIN
  SUPERUSER
  CREATEDB
  CREATEROLE
  REPLICATION
  BYPASSRLS
  PASSWORD :'pwd';
\else
CREATE ROLE supabase_admin
  LOGIN
  SUPERUSER
  CREATEDB
  CREATEROLE
  REPLICATION
  BYPASSRLS
  PASSWORD :'pwd';
\endif

SELECT format('CREATE DATABASE %I', :'realtime_db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'realtime_db')
\gexec

CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID AS $$
  SELECT (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid;
$$ LANGUAGE SQL STABLE;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'adapter_registry_role') THEN
    CREATE ROLE adapter_registry_role LOGIN PASSWORD 'adapter_registry_pw';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.tenant_databases (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        TEXT NOT NULL,
  engine           TEXT NOT NULL CHECK (engine IN ('postgresql','mongodb','mysql','redis','sqlite')),
  name             TEXT NOT NULL,
  connection_enc   BYTEA NOT NULL,
  connection_iv    BYTEA NOT NULL,
  connection_tag   BYTEA NOT NULL,
  connection_salt  BYTEA,
  created_at       TIMESTAMPTZ DEFAULT now(),
  last_healthy_at  TIMESTAMPTZ,
  UNIQUE(tenant_id, name)
);

GRANT CONNECT ON DATABASE postgres TO adapter_registry_role;
GRANT USAGE ON SCHEMA public TO adapter_registry_role;
GRANT SELECT, INSERT ON public.tenant_databases TO adapter_registry_role;

ALTER TABLE public.tenant_databases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_databases FORCE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.current_tenant_id() RETURNS TEXT AS $$
  SELECT current_setting('app.current_user_id', true);
$$ LANGUAGE SQL STABLE;

CREATE TABLE IF NOT EXISTS public.schema_registry (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  database_id UUID NOT NULL,
  name        TEXT NOT NULL,
  engine      TEXT NOT NULL,
  columns     JSONB NOT NULL DEFAULT '[]'::jsonb,
  enable_rls  BOOLEAN DEFAULT true,
  created_by  UUID NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now(),
  UNIQUE (database_id, name)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.schema_registry TO authenticated;

DROP POLICY IF EXISTS tenant_databases_select ON public.tenant_databases;
CREATE POLICY tenant_databases_select ON public.tenant_databases
  FOR SELECT USING (tenant_id = current_tenant_id());

DROP POLICY IF EXISTS tenant_databases_insert ON public.tenant_databases;
CREATE POLICY tenant_databases_insert ON public.tenant_databases
  FOR INSERT WITH CHECK (tenant_id = current_tenant_id());

DROP POLICY IF EXISTS tenant_databases_update ON public.tenant_databases;
CREATE POLICY tenant_databases_update ON public.tenant_databases
  FOR UPDATE USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());

GRANT UPDATE (last_healthy_at) ON public.tenant_databases TO adapter_registry_role;
