# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    005_add_tenant_table.sql                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 15:11:27 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/005_add_tenant_table.sql
-- Migration: Multi-tenant scaffolding — tenants, API keys
-- UP

CREATE TABLE IF NOT EXISTS public.tenants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  plan        TEXT DEFAULT 'free' CHECK (plan IN ('free', 'pro', 'enterprise')),
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.tenant_api_keys (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  key_hash    TEXT NOT NULL UNIQUE,   -- bcrypt hash of the actual key
  key_prefix  TEXT NOT NULL,           -- first 8 chars for display
  name        TEXT,
  scopes      TEXT[] DEFAULT ARRAY['read','write'],
  expires_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ DEFAULT now(),
  last_used_at TIMESTAMPTZ
);

-- Add tenant_id FK to tenant_databases if tenants table exists
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'tenant_databases_tenant_id_fkey'
  ) AND EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'tenant_databases'
      AND column_name = 'tenant_id'
      AND udt_name = 'uuid'
  ) THEN
    ALTER TABLE public.tenant_databases
      ADD CONSTRAINT tenant_databases_tenant_id_fkey
      FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN undefined_table THEN
  -- tenant_databases may not exist yet
  NULL;
END $$;

ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_api_keys ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenants TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_api_keys TO authenticated;

INSERT INTO public.schema_migrations (version, name) VALUES (5, '005_add_tenant_table')
  ON CONFLICT (version) DO NOTHING;

-- DOWN
-- DROP TABLE IF EXISTS public.tenant_api_keys;
-- DROP TABLE IF EXISTS public.tenants;
-- DELETE FROM public.schema_migrations WHERE version = 5;
