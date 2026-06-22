-- 083_env_scope_pubkey.sql — publish each environment's vault42 scope PUBLIC key.
--
-- An environment is the key-bearing scope: secrets seal to its X25519 scope PUBLIC key, while
-- the scope PRIVATE key is wrapped per-member in vault42 (082). Any member writing a secret to
-- the env needs the scope public key, so it lives on the env row (PUBLIC material — safe to
-- expose). `scope_epoch` is the forward-secrecy generation (bumped on rotation). Set/rotated by
-- an admin's `42ctl vault env-init` / `rotate-scope` (PUT .../scopekey). Additive + idempotent.
-- CONTROL-PLANE ONLY. Unused until ENVIRONMENTS_ENABLED + the vault42 scope-key flag are on.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 83) THEN
    RAISE NOTICE 'Migration 083 already applied - skipping';
    RETURN;
  END IF;

  ALTER TABLE public.environments
    ADD COLUMN IF NOT EXISTS scope_pubkey text NULL,
    ADD COLUMN IF NOT EXISTS scope_epoch  integer NOT NULL DEFAULT 0;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (83, '083_env_scope_pubkey') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
