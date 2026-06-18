# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    030_tenancy_isolation.sql                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/02 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/02 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/030_tenancy_isolation.sql
-- Migration: M12 — split tenant_id from user_id everywhere, scope projects and
-- API keys to tenant/project/app, add an `apps` namespace for the realtime and
-- module systems, repair the adapter-registry RLS policy that incorrectly
-- treated user_id as tenant_id.
--
-- Idempotent. Safe to re-run.

-- UP -------------------------------------------------------------------------

-- 1) apps namespace per tenant (used by realtime topics + module manifests)
CREATE TABLE IF NOT EXISTS public.apps (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  slug        TEXT NOT NULL CHECK (char_length(slug) BETWEEN 1 AND 64),
  name        TEXT,
  created_at  TIMESTAMPTZ DEFAULT now(),
  UNIQUE (tenant_id, slug)
);
ALTER TABLE public.apps ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS apps_tenant_isolation ON public.apps;
CREATE POLICY apps_tenant_isolation ON public.apps
  FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
  WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);

-- 2) projects: backfill tenant_id and switch RLS from owner-only to tenant-scoped
ALTER TABLE public.projects
  ADD COLUMN IF NOT EXISTS tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS app_id UUID REFERENCES public.apps(id) ON DELETE SET NULL;

-- Best-effort backfill: if owner_id is a UUID and matches an existing tenant,
-- use it. Otherwise the column stays NULL — controllers must set it explicitly
-- on the next write (M11 already passes tenant_id through the request context).
UPDATE public.projects p
   SET tenant_id = t.id
  FROM public.tenants t
 WHERE p.tenant_id IS NULL
   AND p.owner_id ~ '^[0-9a-fA-F-]{36}$'
   AND t.id::text = p.owner_id;

CREATE INDEX IF NOT EXISTS projects_tenant_idx ON public.projects(tenant_id);
CREATE INDEX IF NOT EXISTS projects_tenant_app_idx ON public.projects(tenant_id, app_id);

-- Replace owner-only policy with tenant-scoped policy. The owner_id column is
-- preserved for audit but no longer the trust boundary.
DROP POLICY IF EXISTS projects_owner_crud ON public.projects;
DROP POLICY IF EXISTS projects_tenant_isolation ON public.projects;
CREATE POLICY projects_tenant_isolation ON public.projects
  FOR ALL USING (
    tenant_id IS NOT NULL
    AND tenant_id::text = auth.current_tenant_id()::text
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND tenant_id::text = auth.current_tenant_id()::text
  );

-- 3) tenant_databases: repair the policy that incorrectly used current_user_id
-- as if it were current_tenant_id. This was the P0 hole from
-- secure-baas-trust-boundary.md: a user belonging to tenant B with the same
-- user_id as a row's tenant_id could read tenant A's DBs.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'tenant_databases') THEN
    EXECUTE 'DROP POLICY IF EXISTS tenant_isolation ON public.tenant_databases';
    EXECUTE 'DROP POLICY IF EXISTS tenant_databases_tenant_isolation ON public.tenant_databases';
    EXECUTE $POLICY$
      CREATE POLICY tenant_databases_tenant_isolation ON public.tenant_databases
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text)
    $POLICY$;
  END IF;
END $$;

-- Optional project + app scope on registered databases (NULL = tenant-wide)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'tenant_databases') THEN
    EXECUTE 'ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.projects(id) ON DELETE SET NULL';
    EXECUTE 'ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS app_id     UUID REFERENCES public.apps(id)     ON DELETE SET NULL';
    EXECUTE 'CREATE INDEX IF NOT EXISTS tenant_databases_project_idx ON public.tenant_databases(tenant_id, project_id)';
    EXECUTE 'CREATE INDEX IF NOT EXISTS tenant_databases_app_idx     ON public.tenant_databases(tenant_id, app_id)';
  END IF;
END $$;

-- 4) tenant_api_keys: add project/app scope so the same key cannot be replayed
-- across all of a tenant's apps. NULL keeps backwards-compatible tenant-wide keys.
ALTER TABLE public.tenant_api_keys
  ADD COLUMN IF NOT EXISTS project_id UUID REFERENCES public.projects(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS app_id     UUID REFERENCES public.apps(id)     ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS tenant_api_keys_tenant_idx
  ON public.tenant_api_keys(tenant_id, project_id, app_id);

DROP POLICY IF EXISTS tenant_api_keys_tenant_isolation ON public.tenant_api_keys;
CREATE POLICY tenant_api_keys_tenant_isolation ON public.tenant_api_keys
  FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
  WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);

-- 5) tenants table itself — RLS by tenant_id = self
DROP POLICY IF EXISTS tenants_self_isolation ON public.tenants;
CREATE POLICY tenants_self_isolation ON public.tenants
  FOR ALL USING (id::text = auth.current_tenant_id()::text)
  WITH CHECK (id::text = auth.current_tenant_id()::text);

-- 6) Grants for new table
GRANT SELECT, INSERT, UPDATE, DELETE ON public.apps TO authenticated;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'adapter_registry_role') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON public.apps TO adapter_registry_role;
  END IF;
END $$;

INSERT INTO public.schema_migrations (version, name)
VALUES (30, '030_tenancy_isolation')
ON CONFLICT (version) DO NOTHING;

-- DOWN -----------------------------------------------------------------------
-- DROP POLICY IF EXISTS projects_tenant_isolation ON public.projects;
-- DROP POLICY IF EXISTS apps_tenant_isolation ON public.apps;
-- DROP POLICY IF EXISTS tenant_databases_tenant_isolation ON public.tenant_databases;
-- DROP POLICY IF EXISTS tenant_api_keys_tenant_isolation ON public.tenant_api_keys;
-- DROP POLICY IF EXISTS tenants_self_isolation ON public.tenants;
-- ALTER TABLE public.projects DROP COLUMN IF EXISTS tenant_id, DROP COLUMN IF EXISTS app_id;
-- ALTER TABLE public.tenant_api_keys DROP COLUMN IF EXISTS project_id, DROP COLUMN IF EXISTS app_id;
-- DROP TABLE IF EXISTS public.apps;
-- DELETE FROM public.schema_migrations WHERE version = 30;
