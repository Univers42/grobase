# File: scripts/migrations/postgresql/050_webauthn_credentials.sql
# Migration 050: per-user WebAuthn / passkey credentials (Track-D D2c).
#
# ADDITIVE ONLY. Creates the durable store the flag-gated passkeys API
# (PASSKEYS_ENABLED, default OFF) writes a registered credential into and reads
# back during a login (assertion) ceremony. gotrue has NO passkey support; this
# is the net-new server-side store for the registration + authentication
# ceremonies driven by github.com/go-webauthn/webauthn.
#
# One row per registered authenticator credential for a user:
#   user_id        : the GoTrue user UUID (sub) that owns this credential. A
#                    user may have MANY passkeys (one per device) — there is no
#                    unique on user_id alone.
#   credential_id  : the authenticator-assigned credential id (raw bytes, stored
#                    base64url-encoded text). GLOBALLY UNIQUE — the login ceremony
#                    looks a credential up by this id, and a credential id is
#                    issued once by an authenticator, so a duplicate is a bug /
#                    forgery attempt and the UNIQUE makes it impossible to register.
#   public_key     : the COSE-encoded public key (raw bytes, base64-std text). The
#                    login ceremony verifies the assertion signature against this.
#   sign_count     : the authenticator signature counter. Bumped on each login;
#                    a non-increasing counter on a real authenticator is a clone
#                    signal (go-webauthn sets Authenticator.CloneWarning). We
#                    persist the latest value so a replay of an OLD assertion is
#                    detectable.
#   aaguid         : the authenticator model id (raw bytes, base64-std text); '' /
#                    all-zero for the "none" attestation format.
#   tenant_id      : the owning tenant slug, for RLS isolation (a passkey belongs
#                    to a user WITHIN a tenant; the house RLS pattern scopes reads).
#
# ISOLATION: house RLS pattern (mirrors tenant_usage 040 / tenant_billing 041 /
# tenant_audit_log 047): per-tenant isolation via auth.current_tenant_id(). The
# control-plane passkeys service writes/reads as the BYPASSRLS service_role and
# ALWAYS binds the lookup key (credential_id for login, user_id for a user's list)
# in its WHERE, so a tenant can never read another tenant's credentials even if
# RLS were misconfigured. No public UPDATE/DELETE grant to authenticated: a
# credential is managed only by the service role on the ceremony path (the
# sign_count bump is a service-role UPDATE), so a tenant cannot forge or tamper
# with the verifier's view of a credential.
#
# Running this migration changes NO existing behavior (no ALTER/DROP of any
# existing object). With PASSKEYS_ENABLED OFF (the default) the /v1/auth/passkeys/*
# routes are never mounted, so nothing ever writes to this table, so it stays
# empty = byte-parity baseline (same story as 040 / 041 / 047).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 50) THEN
    RAISE NOTICE 'Migration 050 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.webauthn_credentials (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     TEXT        NOT NULL DEFAULT '',     -- owning tenant slug (RLS scope)
    user_id       TEXT        NOT NULL,                -- GoTrue user UUID (sub); a user may have many passkeys
    name          TEXT        NOT NULL DEFAULT '',     -- human label (e.g. "Yubikey 5", "iPhone")
    credential_id TEXT        NOT NULL,                -- authenticator credential id, base64url; globally unique
    public_key    TEXT        NOT NULL,                -- COSE public key, base64-std
    sign_count    BIGINT      NOT NULL DEFAULT 0,      -- authenticator signature counter (replay/clone signal)
    aaguid        TEXT        NOT NULL DEFAULT '',     -- authenticator model id, base64-std ('' for "none")
    transports    TEXT        NOT NULL DEFAULT '',     -- comma-joined hints (usb,nfc,internal,…), advisory
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at  TIMESTAMPTZ,
    -- a credential id is issued once by an authenticator; a duplicate is a bug or
    -- a forgery attempt. UNIQUE makes re-registering the same id impossible, and
    -- the login lookup keys off this column.
    CONSTRAINT webauthn_credentials_credential_id_uniq UNIQUE (credential_id)
  );

  -- The login ceremony with a known user looks credentials up by user_id (to
  -- offer allowCredentials); the assertion-finish path looks one up by
  -- credential_id (covered by the UNIQUE above). A user-scoped index serves the
  -- per-user list + the begin-login allowCredentials build.
  CREATE INDEX IF NOT EXISTS webauthn_credentials_user_idx
    ON public.webauthn_credentials (user_id);
  CREATE INDEX IF NOT EXISTS webauthn_credentials_tenant_idx
    ON public.webauthn_credentials (tenant_id);

  -- House RLS pattern (mirrors tenant_usage / tenant_billing / tenant_audit_log):
  -- per-tenant isolation via auth.current_tenant_id(). The control-plane passkeys
  -- service writes/reads as the BYPASSRLS service_role (unaffected); only
  -- anon/authenticated reads are scoped to their own tenant's credential rows.
  ALTER TABLE public.webauthn_credentials ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'webauthn_credentials'
         AND policyname = 'webauthn_credentials_tenant_isolation'
    ) THEN
      CREATE POLICY webauthn_credentials_tenant_isolation ON public.webauthn_credentials
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- The ONLY legitimate writer/mutator (register insert, sign_count bump) is the
  -- BYPASSRLS service role on the ceremony path. authenticated gets SELECT only —
  -- no INSERT/UPDATE/DELETE — so a tenant can list its own passkeys but can never
  -- forge a credential, rewrite a public key, or roll back a sign_count.
  GRANT SELECT                         ON public.webauthn_credentials TO authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.webauthn_credentials TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (50, '050_webauthn_credentials')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.webauthn_credentials;
-- DELETE FROM public.schema_migrations WHERE version = 50;
-- COMMIT;
