# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    001_initial_schema.sql                             :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/001_initial_schema.sql
-- Migration: Initial schema — roles, auth helpers, base tables, RLS
-- UP

CREATE SCHEMA IF NOT EXISTS auth;
ALTER ROLE postgres IN DATABASE postgres SET search_path = auth, public;

-- Migration tracking
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version   INTEGER PRIMARY KEY,
  name      TEXT NOT NULL,
  applied_at TIMESTAMPTZ DEFAULT now()
);

-- Roles (idempotent)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;

-- JWT helper
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID AS $$
  SELECT (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid;
$$ LANGUAGE SQL STABLE;

-- Base tables
CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  name TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  bio TEXT,
  avatar_url TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.posts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  content TEXT,
  is_public BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- RLS
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS users_select_own ON public.users;
CREATE POLICY users_select_own ON public.users
  FOR SELECT USING (auth.uid()::text = id::text);

DROP POLICY IF EXISTS user_profiles_select_own ON public.user_profiles;
CREATE POLICY user_profiles_select_own ON public.user_profiles
  FOR SELECT USING (auth.uid()::text = user_id::text);

DROP POLICY IF EXISTS posts_select ON public.posts;
CREATE POLICY posts_select ON public.posts
  FOR SELECT USING (is_public OR auth.uid()::text = user_id::text);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.users TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.posts TO authenticated;
GRANT SELECT ON public.users TO anon;

INSERT INTO public.schema_migrations (version, name) VALUES (1, '001_initial_schema')
  ON CONFLICT (version) DO NOTHING;

-- DOWN (rollback)
-- DROP POLICY IF EXISTS posts_select ON public.posts;
-- DROP POLICY IF EXISTS user_profiles_select_own ON public.user_profiles;
-- DROP POLICY IF EXISTS users_select_own ON public.users;
-- DROP TABLE IF EXISTS public.posts;
-- DROP TABLE IF EXISTS public.user_profiles;
-- DROP TABLE IF EXISTS public.users;
-- DELETE FROM public.schema_migrations WHERE version = 1;
