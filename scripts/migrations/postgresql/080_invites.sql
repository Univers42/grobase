-- 080_invites.sql — generalized, scope-agnostic invitations (org|project|team|group) with
-- invite-driven pending signup.
--
-- Reuses the 043 org-invite token discipline VERBATIM: a 256-bit token, store only its
-- lower-hex sha256, a 7-day TTL, single-use ATOMIC accept (status pending→accepted in one tx).
-- The 043 org_invites table is KEPT (byte-parity of existing rows); new org invites also route
-- through this unified table so there is ONE accept path. CONTROL-PLANE ONLY (never RLS GUCs /
-- data plane).
--
-- FLAG-GATED OFF = PARITY: INVITES_ENABLED gates issue/accept/list/revoke; EMAIL_OTP_ENABLED
-- additionally gates the pending-signup accept (accept-signup, which mints a session for a
-- not-yet-registered invitee after an email-OTP mailbox proof). OFF (default) ⇒ no routes, no rows.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 80) THEN
    RAISE NOTICE 'Migration 080 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.invites (
    id          uuid        NOT NULL DEFAULT gen_random_uuid(),
    scope_kind  text        NOT NULL CHECK (scope_kind IN ('org','project','team','group')),
    scope_id    uuid        NOT NULL,
    org_id      uuid        NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    email       text        NOT NULL,
    role        text        NOT NULL,
    token_hash  text        NOT NULL,
    invited_by  text        NOT NULL,
    status      text        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','accepted','revoked','expired')),
    expires_at  timestamptz NOT NULL,
    accepted_by text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    accepted_at timestamptz,
    PRIMARY KEY (id)
  );
  CREATE UNIQUE INDEX IF NOT EXISTS invites_token_hash_key ON public.invites (token_hash);
  -- at most one PENDING invite per (scope, email) — mirrors org_invites_org_email_pending_key.
  CREATE UNIQUE INDEX IF NOT EXISTS invites_scope_email_pending_key
    ON public.invites (scope_kind, scope_id, lower(email)) WHERE status = 'pending';
  CREATE INDEX IF NOT EXISTS invites_scope_pending_idx
    ON public.invites (scope_kind, scope_id) WHERE status = 'pending';
  CREATE INDEX IF NOT EXISTS invites_email_idx ON public.invites (lower(email));

  ALTER TABLE public.invites ENABLE ROW LEVEL SECURITY;
  -- the inviter, or any member of the invite's org, may list it. Acceptance is server-side via
  -- the admin pool keyed by token (the cleartext token is the invitee's capability, not a row read).
  DROP POLICY IF EXISTS invites_visibility ON public.invites;
  CREATE POLICY invites_visibility ON public.invites FOR SELECT USING (
    invites.invited_by = auth.current_user_id()::text
    OR (invites.org_id IS NOT NULL AND EXISTS (
          SELECT 1 FROM public.org_members m
            WHERE m.org_id = invites.org_id
              AND m.user_id = auth.current_user_id()::text)));
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.invites TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (80, '080_invites') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
