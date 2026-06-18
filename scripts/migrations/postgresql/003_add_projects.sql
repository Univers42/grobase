# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    003_add_projects.sql                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/003_add_projects.sql
-- Migration: Add projects table for MVP demo
-- UP

CREATE TABLE IF NOT EXISTS public.projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'paused', 'archived')),
  owner_id TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS projects_owner_crud ON public.projects;
CREATE POLICY projects_owner_crud ON public.projects
  FOR ALL USING (auth.uid()::text = owner_id)
  WITH CHECK (auth.uid()::text = owner_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.projects TO authenticated;

INSERT INTO public.schema_migrations (version, name) VALUES (3, '003_add_projects')
  ON CONFLICT (version) DO NOTHING;

-- DOWN
-- DROP POLICY IF EXISTS projects_owner_crud ON public.projects;
-- DROP TABLE IF EXISTS public.projects;
-- DELETE FROM public.schema_migrations WHERE version = 3;
