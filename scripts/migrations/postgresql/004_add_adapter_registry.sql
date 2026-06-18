# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    004_add_adapter_registry.sql                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/004_add_adapter_registry.sql
-- Migration: Adapter registry schema for multi-engine database connections
-- UP

CREATE TABLE IF NOT EXISTS public.tenant_databases (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID NOT NULL,
  engine           TEXT NOT NULL CHECK (engine IN ('postgresql','mongodb','mysql','redis','sqlite')),
  name             TEXT NOT NULL,
  connection_enc   BYTEA NOT NULL,   -- AES-256-GCM encrypted connection string
  connection_iv    BYTEA NOT NULL,   -- IV for decryption
  connection_tag   BYTEA NOT NULL,   -- GCM auth tag
  created_at       TIMESTAMPTZ DEFAULT now(),
  last_healthy_at  TIMESTAMPTZ,
  UNIQUE(tenant_id, name)
);

ALTER TABLE public.tenant_databases ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_databases_owner_crud ON public.tenant_databases;
CREATE POLICY tenant_databases_owner_crud ON public.tenant_databases
  FOR ALL USING (auth.uid()::text = tenant_id::text)
  WITH CHECK (auth.uid()::text = tenant_id::text);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_databases TO authenticated;

INSERT INTO public.schema_migrations (version, name) VALUES (4, '004_add_adapter_registry')
  ON CONFLICT (version) DO NOTHING;

-- DOWN
-- DROP POLICY IF EXISTS tenant_databases_owner_crud ON public.tenant_databases;
-- DROP TABLE IF EXISTS public.tenant_databases;
-- DELETE FROM public.schema_migrations WHERE version = 4;
