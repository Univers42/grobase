-- vault42 zero-knowledge blob substrate — applied into the DEDICATED vault42
-- database by the generic provisioner. Self-contained + idempotent (mirrors
-- grobase migration 071_vault42_secrets.sql, minus the schema_migrations gate so
-- it applies into a fresh database). ZERO plaintext columns: `envelope` is an
-- opaque vault42-core Envelope the server can never decrypt. Owner-scoping on the
-- live (superuser) data-plane path comes from the mount's read_scoped=true; the
-- RLS + FORCE here is defense-in-depth. The anon/authenticated/service_role roles
-- are cluster-wide (created by grobase db-bootstrap), visible in this database.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.vault42_secrets (
  owner_id      text    NOT NULL,
  path          text    NOT NULL,
  secret_id     text    NOT NULL,
  version       integer NOT NULL,
  envelope      bytea   NOT NULL,
  author_pubkey bytea   NOT NULL,
  updated_at    bigint  NOT NULL,
  PRIMARY KEY (owner_id, path, version)
);
CREATE INDEX IF NOT EXISTS vault42_secrets_owner_path
  ON public.vault42_secrets (owner_id, path);
ALTER TABLE public.vault42_secrets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vault42_secrets FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vault42_secrets_owner ON public.vault42_secrets;
CREATE POLICY vault42_secrets_owner ON public.vault42_secrets
  FOR ALL
  USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
  WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
REVOKE ALL ON public.vault42_secrets FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vault42_secrets TO service_role;

CREATE TABLE IF NOT EXISTS public.vault42_audit (
  owner_id  text   NOT NULL,
  seq       bigint NOT NULL,
  ts        bigint NOT NULL,
  actor     text   NOT NULL,
  action    text   NOT NULL,
  target    text   NOT NULL,
  prev_hash text   NOT NULL,
  hash      text   NOT NULL,
  PRIMARY KEY (owner_id, seq)
);
ALTER TABLE public.vault42_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vault42_audit FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vault42_audit_owner ON public.vault42_audit;
CREATE POLICY vault42_audit_owner ON public.vault42_audit
  FOR ALL
  USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
  WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
REVOKE ALL ON public.vault42_audit FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vault42_audit TO service_role;
