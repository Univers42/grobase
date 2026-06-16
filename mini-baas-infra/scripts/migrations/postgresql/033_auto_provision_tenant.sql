-- File: scripts/migrations/postgresql/033_auto_provision_tenant.sql
-- Migration 033: auto-provision a public.tenants row when GoTrue creates a user.
--
-- Closes the signup -> first request loop. After this migration:
--   GoTrue inserts a row into auth.users on signup
--     -> trigger creates a deterministic-slug tenant row owned by that user
--     -> tenant-control POST /v1/tenants/me/bootstrap (JWT-authenticated)
--        finds that row and issues the first API key.
--
-- The trigger function is SECURITY DEFINER (runs as the migration owner,
-- bypasses RLS on public.tenants) because GoTrue's connection has no
-- tenant context and shouldn't need permissions on the public schema.
-- ON CONFLICT (slug) DO NOTHING makes it idempotent against re-runs.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 33) THEN
    RAISE NOTICE 'Migration 033 already applied - skipping';
    RETURN;
  END IF;

  CREATE OR REPLACE FUNCTION public._auto_provision_tenant_from_auth_user()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public, pg_temp
  AS $fn$
  DECLARE
    v_slug TEXT;
    v_name TEXT;
  BEGIN
    -- Deterministic slug derived from the GoTrue user UUID. Lowercased,
    -- dashes stripped to fit ^[a-z0-9][a-z0-9_-]{1,62}$ constraint.
    v_slug := 't-' || replace(NEW.id::text, '-', '');

    -- Display name: prefer user metadata `name`, then email, then slug.
    v_name := COALESCE(
      NULLIF(NEW.raw_user_meta_data->>'name', ''),
      NULLIF(NEW.email, ''),
      v_slug
    );

    INSERT INTO public.tenants (slug, name, owner_user_id, plan, status, metadata)
    VALUES (
      v_slug,
      v_name,
      NEW.id::text,
      'free',
      'active',
      jsonb_build_object(
        'auto_provisioned', true,
        'provisioned_by', 'gotrue_signup_trigger',
        'email', NEW.email
      )
    )
    ON CONFLICT (slug) DO NOTHING;

    RETURN NEW;
  EXCEPTION
    WHEN OTHERS THEN
      -- Never block signup on tenant provisioning failure. tenant-control's
      -- /v1/tenants/me/bootstrap will create the row on first request if the
      -- trigger ever fails (defensive UPSERT path).
      RAISE WARNING 'auto-provision tenant failed for user %: %', NEW.id, SQLERRM;
      RETURN NEW;
  END;
  $fn$;

  DROP TRIGGER IF EXISTS auto_provision_tenant ON auth.users;
  CREATE TRIGGER auto_provision_tenant
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public._auto_provision_tenant_from_auth_user();

  -- Back-fill: provision tenants for any existing GoTrue users that don't
  -- yet have one. Cheap on small dev DBs; gated by NOT EXISTS for prod.
  INSERT INTO public.tenants (slug, name, owner_user_id, plan, status, metadata)
  SELECT
    't-' || replace(u.id::text, '-', ''),
    COALESCE(NULLIF(u.raw_user_meta_data->>'name', ''), NULLIF(u.email, ''),
             't-' || replace(u.id::text, '-', '')),
    u.id::text,
    'free',
    'active',
    jsonb_build_object('auto_provisioned', true, 'provisioned_by', 'backfill_033',
                       'email', u.email)
  FROM auth.users u
  WHERE NOT EXISTS (
    SELECT 1 FROM public.tenants t WHERE t.owner_user_id = u.id::text
  )
  ON CONFLICT (slug) DO NOTHING;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (33, '033_auto_provision_tenant')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual):
-- BEGIN;
-- DROP TRIGGER IF EXISTS auto_provision_tenant ON auth.users;
-- DROP FUNCTION IF EXISTS public._auto_provision_tenant_from_auth_user();
-- DELETE FROM public.schema_migrations WHERE version = 33;
-- COMMIT;
