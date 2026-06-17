# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    010_storage_metadata.sql                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/010_storage_metadata.sql
-- Migration 010: Storage metadata — bucket registry and object tracking
-- Provides row-level security per-owner for storage objects,
-- plus quota & content-type tracking used by storage-router.

BEGIN;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 10) THEN
    RAISE NOTICE 'Migration 010 already applied — skipping';
    RETURN;
  END IF;

  -- ══════════════════════════════════════════════════════════════════
  -- 1. Storage buckets
  -- ══════════════════════════════════════════════════════════════════
  CREATE TABLE IF NOT EXISTS public.storage_buckets (
    id              TEXT PRIMARY KEY,          -- 'avatars', 'documents', 'public' …
    name            TEXT NOT NULL,
    owner_id        UUID,                      -- NULL = system bucket
    is_public       BOOLEAN DEFAULT false,     -- public buckets allow anon read
    file_size_limit BIGINT DEFAULT 52428800,   -- 50 MB default
    allowed_mime_types TEXT[] DEFAULT '{}',     -- empty = all allowed
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now()
  );

  ALTER TABLE public.storage_buckets ENABLE ROW LEVEL SECURITY;

  -- Anyone can list buckets (names only)
  CREATE POLICY buckets_select ON public.storage_buckets
    FOR SELECT USING (true);

  -- Only admin / service_role can manage buckets
  CREATE POLICY buckets_admin ON public.storage_buckets
    FOR ALL TO authenticated USING (
      'admin' = ANY (public.user_roles_array(auth.uid()))
    );

  GRANT SELECT ON public.storage_buckets TO anon, authenticated;
  GRANT ALL    ON public.storage_buckets TO service_role;

  -- Seed default buckets
  INSERT INTO public.storage_buckets (id, name, is_public, file_size_limit, allowed_mime_types) VALUES
    ('avatars',    'Avatars',    true,  5242880,   ARRAY['image/jpeg','image/png','image/webp','image/gif']),
    ('documents',  'Documents',  false, 52428800,  ARRAY[]::TEXT[]),
    ('public',     'Public',     true,  10485760,  ARRAY[]::TEXT[])
  ON CONFLICT DO NOTHING;

  -- ══════════════════════════════════════════════════════════════════
  -- 2. Storage objects
  -- ══════════════════════════════════════════════════════════════════
  CREATE TABLE IF NOT EXISTS public.storage_objects (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id     TEXT NOT NULL REFERENCES public.storage_buckets(id),
    name          TEXT NOT NULL,             -- 'user123/photo.jpg'
    owner_id      UUID NOT NULL,
    size          BIGINT DEFAULT 0,
    content_type  TEXT DEFAULT 'application/octet-stream',
    etag          TEXT,
    metadata      JSONB DEFAULT '{}'::jsonb,
    version       TEXT DEFAULT '1',
    created_at    TIMESTAMPTZ DEFAULT now(),
    updated_at    TIMESTAMPTZ DEFAULT now(),
    UNIQUE (bucket_id, name)
  );

  CREATE INDEX IF NOT EXISTS idx_storage_objects_owner ON public.storage_objects(owner_id);
  CREATE INDEX IF NOT EXISTS idx_storage_objects_bucket ON public.storage_objects(bucket_id);

  ALTER TABLE public.storage_objects ENABLE ROW LEVEL SECURITY;

  -- Owner can manage own objects
  CREATE POLICY objects_owner_select ON public.storage_objects
    FOR SELECT TO authenticated USING (owner_id = auth.uid());

  CREATE POLICY objects_owner_insert ON public.storage_objects
    FOR INSERT TO authenticated WITH CHECK (owner_id = auth.uid());

  CREATE POLICY objects_owner_update ON public.storage_objects
    FOR UPDATE TO authenticated USING (owner_id = auth.uid());

  CREATE POLICY objects_owner_delete ON public.storage_objects
    FOR DELETE TO authenticated USING (owner_id = auth.uid());

  -- Anyone can read from public buckets
  CREATE POLICY objects_public_select ON public.storage_objects
    FOR SELECT USING (
      EXISTS (
        SELECT 1 FROM public.storage_buckets b
         WHERE b.id = bucket_id AND b.is_public = true
      )
    );

  -- Service role full access
  GRANT ALL ON public.storage_objects TO service_role;
  GRANT ALL ON public.storage_buckets TO service_role;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.storage_objects TO authenticated;

  -- ══════════════════════════════════════════════════════════════════
  -- 3. Quota helper
  -- ══════════════════════════════════════════════════════════════════
  CREATE OR REPLACE FUNCTION public.user_storage_usage(p_user_id UUID)
  RETURNS BIGINT AS $fn$
    SELECT COALESCE(SUM(size), 0)
      FROM public.storage_objects
     WHERE owner_id = p_user_id;
  $fn$ LANGUAGE sql STABLE SECURITY DEFINER;

  -- Record migration
  INSERT INTO public.schema_migrations (version, name) VALUES (10, '010_storage_metadata');

END $$;

COMMIT;
