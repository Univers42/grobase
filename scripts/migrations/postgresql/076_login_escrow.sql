-- 076_login_escrow.sql — multi-device keystore escrow (zero-knowledge).
--
-- Additive + idempotent. Stores ONE passphrase-wrapped keystore blob per account email
-- (the Argon2id `KeystoreBlob` from vault42-core — the server can NEVER decrypt it; a
-- leak yields only ciphertext). PUT/GET are gated by an email-OTP proof, so a second
-- device proves control of the mailbox before fetching, then unlocks locally with the
-- passphrase. RLS-forced, service_role only.
--
-- FLAG-GATED OFF = PARITY: the /v1/auth/escrow routes mount with the OTP feature
-- (EMAIL_OTP_ENABLED). OFF (default) ⇒ no routes, no rows — byte-identical to today.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 76) THEN
    RAISE NOTICE 'Migration 076 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.login_escrow (
    email      text   NOT NULL,
    blob       text   NOT NULL,
    version    integer NOT NULL DEFAULT 1,
    updated_at bigint NOT NULL,
    PRIMARY KEY (email)
  );

  ALTER TABLE public.login_escrow ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.login_escrow FORCE  ROW LEVEL SECURITY;
  REVOKE ALL ON public.login_escrow FROM anon, authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.login_escrow TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (76, '076_login_escrow') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
