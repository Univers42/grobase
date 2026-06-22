-- 084_vault42_env_secrets.sql — vault42 SHARED env-secret store (the GrobaseStore backend).
--
-- An environment secret is sealed CLIENT-SIDE to the env's X25519 scope PUBLIC key, stored
-- ONCE keyed by (scope_id, epoch, path, version), and readable by ANY scope member — because
-- the seal IS the access control (only a holder of the scope private key decrypts). OPAQUE to
-- the server: `envelope` is base64 (the serialized vault42-core Envelope it can never decrypt);
-- `author_pubkey` is the PUBLIC verification sidecar. Stored under one stable owner
-- (`vault42:env-secrets`) so the data-plane `read_scoped` mount surfaces the SAME shared rows
-- to every member's minted JWT — the deliberate exception to per-owner scoping (the seal, not
-- the owner, is the gate). Additive + idempotent (mirrors 071/082). Flag-gated by
-- VAULT42_SCOPE_KEYS_ENABLED (server-side) — the table is simply unused until that flag flips.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 84) THEN
    RAISE NOTICE 'Migration 084 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.vault42_env_secrets (
    owner_id      uuid        NOT NULL,
    scope_id      text        NOT NULL,
    epoch         integer     NOT NULL,
    path          text        NOT NULL,
    version       integer     NOT NULL,
    envelope      text        NOT NULL,
    author_pubkey text        NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_id, scope_id, epoch, path, version)
  );
  CREATE INDEX IF NOT EXISTS vault42_env_secrets_scope
    ON public.vault42_env_secrets (scope_id, epoch, path);
  ALTER TABLE public.vault42_env_secrets ENABLE ROW LEVEL SECURITY;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (84, '084_vault42_env_secrets') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
