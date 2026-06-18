# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    009_translations.sql                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/009_translations.sql
-- Migration 009: Internationalisation — language registry and translation KV store
-- Supports LTR & RTL languages, namespaced keys, per-language content.

BEGIN;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 9) THEN
    RAISE NOTICE 'Migration 009 already applied — skipping';
    RETURN;
  END IF;

  -- ══════════════════════════════════════════════════════════════════
  -- 1. Supported languages
  -- ══════════════════════════════════════════════════════════════════
  CREATE TABLE IF NOT EXISTS public.supported_languages (
    code         TEXT PRIMARY KEY,          -- 'en', 'fr', 'ar', 'he' …
    name_native  TEXT NOT NULL,             -- 'English', 'Français', 'العربية'
    name_english TEXT NOT NULL,             -- 'English', 'French', 'Arabic'
    direction    TEXT NOT NULL DEFAULT 'ltr'
                   CHECK (direction IN ('ltr','rtl')),
    is_default   BOOLEAN DEFAULT false,
    is_active    BOOLEAN DEFAULT true,
    created_at   TIMESTAMPTZ DEFAULT now()
  );

  -- Ensure exactly one default language
  CREATE UNIQUE INDEX IF NOT EXISTS idx_supported_languages_default
    ON public.supported_languages (is_default) WHERE is_default = true;

  -- Seed initial languages
  INSERT INTO public.supported_languages (code, name_native, name_english, direction, is_default) VALUES
    ('en', 'English',   'English',  'ltr', true),
    ('fr', 'Français',  'French',   'ltr', false),
    ('es', 'Español',   'Spanish',  'ltr', false),
    ('ar', 'العربية',    'Arabic',   'rtl', false),
    ('he', 'עברית',     'Hebrew',   'rtl', false)
  ON CONFLICT DO NOTHING;

  -- Public read for everyone, write for admins
  ALTER TABLE public.supported_languages ENABLE ROW LEVEL SECURITY;

  CREATE POLICY languages_select ON public.supported_languages
    FOR SELECT USING (true);

  CREATE POLICY languages_admin ON public.supported_languages
    FOR ALL TO authenticated USING (
      'admin' = ANY (public.user_roles_array(auth.uid()))
    );

  GRANT SELECT ON public.supported_languages TO anon, authenticated;
  GRANT ALL    ON public.supported_languages TO service_role;

  -- ══════════════════════════════════════════════════════════════════
  -- 2. Translations key–value store
  -- ══════════════════════════════════════════════════════════════════
  CREATE TABLE IF NOT EXISTS public.translations (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    namespace     TEXT NOT NULL DEFAULT 'common',   -- 'common', 'auth', 'dashboard' …
    key           TEXT NOT NULL,                     -- 'greeting', 'btn.save' …
    language_code TEXT NOT NULL REFERENCES public.supported_languages(code),
    value         TEXT NOT NULL,
    created_at    TIMESTAMPTZ DEFAULT now(),
    updated_at    TIMESTAMPTZ DEFAULT now(),
    UNIQUE (namespace, key, language_code)
  );

  CREATE INDEX IF NOT EXISTS idx_translations_ns_lang
    ON public.translations(namespace, language_code);

  ALTER TABLE public.translations ENABLE ROW LEVEL SECURITY;

  -- Public read
  CREATE POLICY translations_select ON public.translations
    FOR SELECT USING (true);

  -- Admin write
  CREATE POLICY translations_admin ON public.translations
    FOR ALL TO authenticated USING (
      'admin' = ANY (public.user_roles_array(auth.uid()))
    );

  GRANT SELECT ON public.translations TO anon, authenticated;
  GRANT ALL    ON public.translations TO service_role;

  -- ══════════════════════════════════════════════════════════════════
  -- 3. Helper: get translation with fallback
  -- ══════════════════════════════════════════════════════════════════
  CREATE OR REPLACE FUNCTION public.t(
    p_key       TEXT,
    p_lang      TEXT DEFAULT 'en',
    p_namespace TEXT DEFAULT 'common'
  ) RETURNS TEXT AS $fn$
  DECLARE
    v_value TEXT;
    v_fallback TEXT;
  BEGIN
    -- Try requested language
    SELECT value INTO v_value
      FROM public.translations
     WHERE key = p_key AND language_code = p_lang AND namespace = p_namespace;

    IF v_value IS NOT NULL THEN
      RETURN v_value;
    END IF;

    -- Fallback to default language
    SELECT value INTO v_fallback
      FROM public.translations t
      JOIN public.supported_languages l ON l.code = t.language_code
     WHERE t.key = p_key AND t.namespace = p_namespace AND l.is_default = true;

    RETURN COALESCE(v_fallback, p_key);     -- worst-case: return the key itself
  END;
  $fn$ LANGUAGE plpgsql STABLE;

  -- Record migration
  INSERT INTO public.schema_migrations (version, name) VALUES (9, '009_translations');

END $$;

COMMIT;
