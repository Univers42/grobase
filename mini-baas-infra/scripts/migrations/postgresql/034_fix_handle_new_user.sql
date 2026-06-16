-- File: scripts/migrations/postgresql/034_fix_handle_new_user.sql
-- Migration 034: fix pre-existing public.handle_new_user() trigger.
--
-- Earlier migrations defined `handle_new_user()` referencing an undefined
-- identifier `email_separator` instead of the literal `'@'`. This causes
-- every GoTrue signup to fail with:
--   ERROR: column "email_separator" does not exist
--
-- The fix is mechanical: replace the bare identifier with the literal.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 34) THEN
    RAISE NOTICE 'Migration 034 already applied - skipping';
    RETURN;
  END IF;

  -- Only redefine if the broken function exists (no-op on fresh installs
  -- that already have the fixed shape).
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'handle_new_user' AND pronamespace = 'public'::regnamespace
  ) THEN
    CREATE OR REPLACE FUNCTION public.handle_new_user()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $fn$
    BEGIN
      INSERT INTO public.users (id, email, name)
      VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1))
      )
      ON CONFLICT (id) DO NOTHING;

      INSERT INTO public.user_profiles (user_id, display_name, avatar_url)
      VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1)),
        NEW.raw_user_meta_data->>'avatar_url'
      )
      ON CONFLICT (user_id) DO NOTHING;

      RETURN NEW;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING 'handle_new_user failed for %: %', NEW.id, SQLERRM;
        RETURN NEW;
    END;
    $fn$;
  END IF;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (34, '034_fix_handle_new_user')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;
