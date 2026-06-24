-- 081_user_pubkeys.sql — member X25519 public-key registry + the grant-fulfilment seam.
--
-- The wrap-target registry the vault42 zero-knowledge crypto layer needs: to wrap an
-- environment's scope key to "every current member of project P", an admin's client maps each
-- member's GoTrue subject → their X25519 PUBLIC key. NO PRIVATE KEYS are ever stored.
-- `pubkey_sig` is the member's Ed25519 self-signature over (user_id || org_id || x25519_pub) —
-- proof-of-possession so a malicious server/co-member cannot substitute an attacker wrap-target.
--
-- grant_key_wraps is the SEAM between the two planes: the control plane owns the QUESTION
-- ("is this grant provisioned to this member?"), vault42 writes the ANSWER (one row) after it
-- wraps the scope key. A live project_grant with no wrap row = "authorized but not yet
-- provisioned" (surfaced as pending-provision; never silent). CONTROL-PLANE ONLY.
--
-- FLAG-GATED OFF = PARITY: USER_PUBKEYS_ENABLED gates /v1/users/*/pubkey + /grants/{id}/fulfilled.
-- OFF (default) ⇒ no routes, no rows.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 81) THEN
    RAISE NOTICE 'Migration 081 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.user_pubkeys (
    user_id     text        NOT NULL,
    org_id      uuid        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    ed25519_pub text        NOT NULL,
    x25519_pub  text        NOT NULL,
    v42_address text        NOT NULL,
    pubkey_sig  text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    rotated_at  timestamptz,
    PRIMARY KEY (user_id, org_id)
  );
  CREATE INDEX IF NOT EXISTS user_pubkeys_org ON public.user_pubkeys (org_id);

  -- the crypto layer records here that an environment scope key was wrapped to a member for a grant.
  CREATE TABLE IF NOT EXISTS public.grant_key_wraps (
    grant_id   uuid        NOT NULL REFERENCES public.project_grants(id) ON DELETE CASCADE,
    user_id    text        NOT NULL,
    wrapped_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (grant_id, user_id)
  );

  ALTER TABLE public.user_pubkeys    ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.grant_key_wraps ENABLE ROW LEVEL SECURITY;
  -- a user may read pubkeys of co-members of any org they belong to (to wrap scope keys to them).
  DROP POLICY IF EXISTS user_pubkeys_org_visibility ON public.user_pubkeys;
  CREATE POLICY user_pubkeys_org_visibility ON public.user_pubkeys FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.org_members m
              WHERE m.org_id = user_pubkeys.org_id
                AND m.user_id = auth.current_user_id()::text));
  DROP POLICY IF EXISTS grant_key_wraps_visibility ON public.grant_key_wraps;
  CREATE POLICY grant_key_wraps_visibility ON public.grant_key_wraps FOR SELECT USING (
    grant_key_wraps.user_id = auth.current_user_id()::text
    OR EXISTS (SELECT 1 FROM public.project_grants g JOIN public.org_members m ON m.org_id = g.org_id
                 WHERE g.id = grant_key_wraps.grant_id
                   AND m.user_id = auth.current_user_id()::text));
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_pubkeys    TO authenticated, service_role;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.grant_key_wraps TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (81, '081_user_pubkeys') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
