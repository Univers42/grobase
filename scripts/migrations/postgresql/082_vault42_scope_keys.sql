-- 082_vault42_scope_keys.sql — vault42 scope-key wraps (the KEK-hierarchy substrate).
--
-- Each row is a GrantedScopeKey: an ENVIRONMENT's X25519 PRIVATE key wrapped to ONE member's
-- personal X25519 key (produced client-side by vault42-core::keyset::grant_scope_key, signed by
-- the granting admin). OPAQUE to the server: `granted_blob` is base64; the server verifies the
-- granter signature but can NEVER decrypt it. ZERO plaintext, ZERO private keys in cleartext.
--
-- owner_id is the MEMBER (recipient) the key is wrapped to — so a member reads ONLY their own
-- wraps under the data plane's owner-scoping (read_scoped), exactly like the `share` deposit
-- model (a wrap is deposited into the recipient's namespace by the granting admin). The control
-- plane's grant_key_wraps (081) is the admin-visible fulfilment record; this table is the actual
-- wrapped-key material the member fetches.
--
-- Additive + idempotent (mirrors 071_vault42_secrets). Flag-gated by VAULT42_SCOPE_KEYS_ENABLED
-- (server-side) — the table is simply unused until that flag flips.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 82) THEN
    RAISE NOTICE 'Migration 082 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.vault42_scope_keys (
    owner_id       uuid        NOT NULL,
    scope_id       text        NOT NULL,
    epoch          integer     NOT NULL,
    granted_blob   text        NOT NULL,
    granter_pubkey text        NOT NULL,
    wrapped_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_id, scope_id, epoch)
  );
  CREATE INDEX IF NOT EXISTS vault42_scope_keys_scope
    ON public.vault42_scope_keys (scope_id, epoch);
  ALTER TABLE public.vault42_scope_keys ENABLE ROW LEVEL SECURITY;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (82, '082_vault42_scope_keys') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
