-- 075_login_otp.sql — email login OTP (second factor): a 6-digit code mailed to the
-- account's registered address, entered back in the terminal (Bitwarden-style).
--
-- Additive + idempotent. CONTROL-PLANE ONLY. The code is stored ONLY as a peppered
-- sha256 hash (never cleartext); a 6-digit code is low-entropy, so the protection is
-- (a) the server pepper makes a DB leak useless for offline guessing, (b) a short TTL
-- (~5 min), and (c) a hard attempt cap. RLS-forced, service_role only.
--
-- FLAG-GATED OFF = PARITY: the /v1/auth/otp/* routes mount ONLY when EMAIL_OTP_ENABLED
-- is truthy. OFF (default) ⇒ no routes, no rows — byte-identical to today.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 75) THEN
    RAISE NOTICE 'Migration 075 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.login_otps (
    id          uuid        NOT NULL DEFAULT gen_random_uuid(),
    email       text        NOT NULL,
    code_hash   text        NOT NULL,
    purpose     text        NOT NULL DEFAULT 'login',
    attempts    integer     NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    consumed_at timestamptz NULL,
    PRIMARY KEY (id)
  );
  -- the verifier reads the latest LIVE (unconsumed, unexpired) code per email.
  CREATE INDEX IF NOT EXISTS login_otps_email_live
    ON public.login_otps (lower(email), created_at DESC) WHERE consumed_at IS NULL;

  ALTER TABLE public.login_otps ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.login_otps FORCE  ROW LEVEL SECURITY;
  REVOKE ALL ON public.login_otps FROM anon, authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.login_otps TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (75, '075_login_otp') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
