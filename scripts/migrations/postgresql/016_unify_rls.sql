# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    016_unify_rls.sql                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 15:25:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/016_unify_rls.sql
-- Migration 016 (M3 coherence): one RLS identity helper for PostgREST and apps.

BEGIN;

CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'sub',
    NULLIF(current_setting('app.current_user_id', true), '')
  )::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT auth.current_user_id();
$$;

CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id',
    NULLIF(current_setting('app.current_tenant_id', true), ''),
    auth.current_user_id()::text
  )::uuid;
$$;

CREATE OR REPLACE FUNCTION public.current_tenant_id() RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT auth.current_tenant_id()::text;
$$;

GRANT EXECUTE ON FUNCTION auth.current_user_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.current_tenant_id() TO anon, authenticated, service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'adapter_registry_role') THEN
    GRANT USAGE ON SCHEMA auth TO adapter_registry_role;
    GRANT EXECUTE ON FUNCTION auth.current_user_id() TO adapter_registry_role;
    GRANT EXECUTE ON FUNCTION auth.uid() TO adapter_registry_role;
    GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO adapter_registry_role;
    GRANT EXECUTE ON FUNCTION public.current_tenant_id() TO adapter_registry_role;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regclass('auth.tenant_databases') IS NOT NULL THEN
    DROP TABLE auth.tenant_databases CASCADE;
  END IF;

  IF to_regclass('public.users') IS NOT NULL THEN
    DROP POLICY IF EXISTS users_select_own ON public.users;
    CREATE POLICY users_select_own ON public.users
      FOR SELECT USING (auth.current_user_id()::text = id::text);
  END IF;

  IF to_regclass('public.user_profiles') IS NOT NULL THEN
    DROP POLICY IF EXISTS user_profiles_select_own ON public.user_profiles;
    CREATE POLICY user_profiles_select_own ON public.user_profiles
      FOR SELECT USING (auth.current_user_id()::text = user_id::text);
  END IF;

  IF to_regclass('public.posts') IS NOT NULL THEN
    DROP POLICY IF EXISTS posts_select ON public.posts;
    CREATE POLICY posts_select ON public.posts
      FOR SELECT USING (is_public OR auth.current_user_id()::text = user_id::text);
  END IF;

  IF to_regclass('public.mock_orders') IS NOT NULL THEN
    DROP POLICY IF EXISTS mock_orders_owner_crud ON public.mock_orders;
    CREATE POLICY mock_orders_owner_crud ON public.mock_orders
      FOR ALL USING (auth.current_user_id()::text = owner_id)
      WITH CHECK (auth.current_user_id()::text = owner_id);
  END IF;

  IF to_regclass('public.projects') IS NOT NULL THEN
    DROP POLICY IF EXISTS projects_owner_crud ON public.projects;
    CREATE POLICY projects_owner_crud ON public.projects
      FOR ALL USING (auth.current_user_id()::text = owner_id)
      WITH CHECK (auth.current_user_id()::text = owner_id);
  END IF;

  IF to_regclass('public.audit_log') IS NOT NULL THEN
    DROP POLICY IF EXISTS audit_log_self_read ON public.audit_log;
    CREATE POLICY audit_log_self_read ON public.audit_log
      FOR SELECT TO authenticated
      USING (actor_id IS NOT NULL AND actor_id = auth.current_user_id());
  END IF;

  IF to_regclass('public.tenant_databases') IS NOT NULL THEN
    DROP POLICY IF EXISTS tenant_databases_select ON public.tenant_databases;
    CREATE POLICY tenant_databases_select ON public.tenant_databases
      FOR SELECT USING (tenant_id::text = auth.current_tenant_id()::text);

    DROP POLICY IF EXISTS tenant_databases_insert ON public.tenant_databases;
    CREATE POLICY tenant_databases_insert ON public.tenant_databases
      FOR INSERT WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);

    DROP POLICY IF EXISTS tenant_databases_update ON public.tenant_databases;
    CREATE POLICY tenant_databases_update ON public.tenant_databases
      FOR UPDATE USING (tenant_id::text = auth.current_tenant_id()::text)
      WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);

    DROP POLICY IF EXISTS tenant_isolation ON public.tenant_databases;
    CREATE POLICY tenant_isolation ON public.tenant_databases
      FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
      WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
  END IF;

  IF to_regclass('gdpr.user_consent') IS NOT NULL THEN
    DROP POLICY IF EXISTS consent_owner ON gdpr.user_consent;
    CREATE POLICY consent_owner ON gdpr.user_consent
      FOR ALL USING (user_id = auth.current_user_id()::text)
      WITH CHECK (user_id = auth.current_user_id()::text);
  END IF;

  IF to_regclass('gdpr.data_deletion_request') IS NOT NULL THEN
    DROP POLICY IF EXISTS deletion_owner ON gdpr.data_deletion_request;
    CREATE POLICY deletion_owner ON gdpr.data_deletion_request
      FOR ALL USING (user_id = auth.current_user_id()::text)
      WITH CHECK (user_id = auth.current_user_id()::text);
  END IF;

  IF to_regclass('session.user_sessions') IS NOT NULL THEN
    DROP POLICY IF EXISTS user_own_sessions ON session.user_sessions;
    CREATE POLICY user_own_sessions ON session.user_sessions
      FOR ALL USING (user_id = auth.current_user_id()::text)
      WITH CHECK (user_id = auth.current_user_id()::text);
  END IF;
END $$;

INSERT INTO public.schema_migrations (version, name)
VALUES (16, '016_unify_rls')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- DOWN (manual, gated): recreate legacy auth.uid() and policies from previous migrations.