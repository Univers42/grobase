-- Migration 094: every tenant_databases mount row carries a monotonically
-- increasing revision, bumped by trigger whenever its stored credential
-- changes, and GET /databases/{id}/connect returns it.
--
-- WHY: the data-plane pool key is derived from the mount's resolved credential
-- alone, so a rotated DSN kept the SAME key and reused the old pool — the
-- rotation never took effect. Folding revision into that key (query-router
-- side) gives a rotated credential a fresh pool.
--
-- ADDITIVE: one column, revision integer NOT NULL DEFAULT 1. Every existing
-- row reads 1 ⇒ never rotated ⇒ byte-parity with the pre-094 baseline. The
-- BEFORE UPDATE trigger bumps revision only when one of the nine credential
-- columns IS DISTINCT FROM its OLD value; any other UPDATE — the control
-- plane's last_healthy_at stamp included — re-pins NEW.revision to
-- OLD.revision, so a caller can never set revision by hand, up or down.
--
-- Idempotent (re-runnable): the column add is IF NOT EXISTS, the function is
-- OR REPLACE, the trigger is DROP IF EXISTS + CREATE. A no-op where the table
-- does not exist (a fresh DB gets the same DDL from adapterregistry/schema.go).
--
-- DOWN (manual, drops the bump):
-- DROP TRIGGER IF EXISTS tenant_databases_bump_revision ON public.tenant_databases;
-- DROP FUNCTION IF EXISTS public.tenant_databases_bump_revision();
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS revision;
-- DELETE FROM public.schema_migrations WHERE version = 94;
DO $$
BEGIN
  IF to_regclass('public.tenant_databases') IS NOT NULL THEN
    -- 1 = never rotated; only the trigger below ever moves it, and only up.
    ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 1;

    -- IS DISTINCT FROM (not <>) so NULL<->NULL stays "unchanged" and any
    -- NULL<->value transition counts as a credential change.
    CREATE OR REPLACE FUNCTION public.tenant_databases_bump_revision()
    RETURNS trigger LANGUAGE plpgsql AS $fn$
    BEGIN
      IF NEW.connection_enc   IS DISTINCT FROM OLD.connection_enc
      OR NEW.connection_iv    IS DISTINCT FROM OLD.connection_iv
      OR NEW.connection_tag   IS DISTINCT FROM OLD.connection_tag
      OR NEW.connection_salt  IS DISTINCT FROM OLD.connection_salt
      OR NEW.cred_provider    IS DISTINCT FROM OLD.cred_provider
      OR NEW.cred_reference   IS DISTINCT FROM OLD.cred_reference
      OR NEW.cred_version     IS DISTINCT FROM OLD.cred_version
      OR NEW.cmek_wrapped_dek IS DISTINCT FROM OLD.cmek_wrapped_dek
      OR NEW.cmek_kms_key_id  IS DISTINCT FROM OLD.cmek_kms_key_id
      THEN
        NEW.revision := OLD.revision + 1;
      ELSE
        NEW.revision := OLD.revision;
      END IF;
      RETURN NEW;
    END;
    $fn$;

    DROP TRIGGER IF EXISTS tenant_databases_bump_revision ON public.tenant_databases;
    CREATE TRIGGER tenant_databases_bump_revision
      BEFORE UPDATE ON public.tenant_databases
      FOR EACH ROW EXECUTE FUNCTION public.tenant_databases_bump_revision();
  END IF;
END $$;

INSERT INTO public.schema_migrations (version, name)
SELECT 94, '094_tenant_databases_revision'
WHERE NOT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 94);
