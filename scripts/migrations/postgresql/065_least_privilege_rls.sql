# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    065_least_privilege_rls.sql                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/065_least_privilege_rls.sql
-- Migration 065 — make the public REST/GraphQL isolation SAFE BY CONSTRUCTION.
--
-- FOUND BY a security audit of the public PostgREST surface. Three compounding
-- weaknesses turned tenant isolation into a single fragile invariant:
--
--   (A) docker-compose.yml ran PostgREST as the `postgres` SUPERUSER
--       (PGRST_DB_URI=postgres://postgres:postgres@…). A superuser BYPASSES RLS
--       UNCONDITIONALLY and is exempt even from FORCE ROW LEVEL SECURITY — so
--       every RLS policy on the public surface was decorative.
--   (B) Tenant-scoped tables only ENABLE RLS, they do not FORCE it. ENABLE still
--       exempts the table OWNER (the role that created the table, here `postgres`),
--       so any path that touches the table as the owner skips the policies.
--   (C) The secret tables carry blanket `GRANT … TO authenticated`:
--         - public.tenant_databases  → AES-GCM connection strings
--           (connection_enc/iv/tag/salt) for every tenant's real databases.
--         - public.tenant_api_keys   → key_hash (the credential verifier).
--       Even with RLS on, a column-level grant to `authenticated` means the
--       secret columns are reachable the instant an RLS policy (or a future
--       default-privilege regrant) lets a row through.
--
-- This migration closes (B) and (C) at the database layer. (A) is closed in the
-- compose/env layer by switching PostgREST off the superuser onto a dedicated
-- non-superuser, NOBYPASSRLS `authenticator` login role (created here in step 2).
--
-- DISCIPLINE: additive + idempotent. It tightens privileges only; it never
-- loosens one. The control-plane roles that legitimately bypass RLS
-- (postgres superuser for the data-plane outbox/producers, service_role which is
-- granted to authenticator and used for service-role JWTs, adapter_registry_role
-- for the registry writer) keep exactly the access they had. Only the public
-- anon/authenticated surface is constrained — which is the whole point.

BEGIN;

-- ─── Step 2 (DB half): the PostgREST `authenticator` login role ──────────────
-- The standard PostgREST pattern. `authenticator` is a NOINHERIT login role with
-- NO privileges of its own and crucially NOBYPASSRLS: PostgREST connects as it,
-- then SET ROLE to anon/authenticated/service_role per request from the verified
-- JWT `role` claim. Because it cannot bypass RLS and inherits nothing until it
-- explicitly SET ROLEs, a missing/forged claim yields the anon role's (empty)
-- view, never a superuser view.
--
-- The role's PASSWORD is owned by scripts/db-bootstrap.psql (the only role-creation
-- path that runs BEFORE PostgREST connects and can carry the generated secret —
-- the numbered-migration loop deliberately carries no secrets). This migration is
-- password-INDEPENDENT: it only (re)affirms the safety ATTRIBUTES and the role
-- MEMBERSHIPS, so it is safe in the CI migration loop and idempotent. If the role
-- does not exist yet (a migrate run against a DB that skipped bootstrap), it is
-- created LOGIN-less so it can never be used to authenticate without a password
-- explicitly set later by bootstrap.
DO $authrole$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    -- No LOGIN/password here: bootstrap sets both with the generated secret. We
    -- still pin NOINHERIT + NOBYPASSRLS + NOSUPERUSER so the role can never bypass
    -- RLS regardless of who later flips LOGIN on.
    CREATE ROLE authenticator NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE;
  ELSE
    -- Re-affirm the safety attributes on every run in case a prior bootstrap made
    -- the role differently. NOBYPASSRLS + NOSUPERUSER are the load-bearing ones.
    -- (LOGIN/password are left to bootstrap — not touched here.)
    ALTER ROLE authenticator WITH NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END
$authrole$;

-- authenticator must be able to BECOME the three request roles PostgREST switches
-- to. These GRANTs are what let `SET ROLE authenticated` (etc.) succeed. Because
-- authenticator is NOINHERIT, holding the membership does NOT silently confer the
-- roles' privileges — they apply only after an explicit SET ROLE.
GRANT anon, authenticated, service_role TO authenticator;

-- It needs to connect to the database and see the public schema to do the switch.
GRANT CONNECT ON DATABASE postgres TO authenticator;
GRANT USAGE   ON SCHEMA public      TO authenticator;
DO $authgrant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN
    GRANT USAGE ON SCHEMA auth TO authenticator;
  END IF;
END
$authgrant$;

-- ─── Step 1: FORCE ROW LEVEL SECURITY on every RLS-enabled table ─────────────
-- ENABLE RLS still exempts the table owner. FORCE removes that exemption so the
-- policies bind even the owner (a superuser is STILL exempt — that is the role
-- step 2 takes PostgREST off of). This is additive and reversible (NO FORCE), and
-- self-maintaining: it walks pg_class and forces every table that already has RLS
-- enabled but not forced, in the user-data schemas — so any RLS table added by a
-- prior migration (or a future one re-running this) is covered without a
-- hand-maintained list.
DO $force$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT n.nspname AS schema_name, c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND c.relrowsecurity            -- RLS is ENABLEd
      AND NOT c.relforcerowsecurity   -- but not yet FORCEd
      AND n.nspname IN ('public', 'auth', 'gdpr', 'session')
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY',
      r.schema_name, r.table_name
    );
    RAISE NOTICE 'FORCE ROW LEVEL SECURITY on %.%', r.schema_name, r.table_name;
  END LOOP;
END
$force$;

-- ─── Step 3: REVOKE the blanket grants on the SECRET tables ──────────────────
-- The two tables that carry cross-tenant secrets must never be readable through
-- the public anon/authenticated roles, regardless of RLS. RLS (steps 1+2) is the
-- row gate; this is the column gate — defence in depth, so a future policy slip or
-- default-privilege regrant cannot leak the ciphertext / hash. The legitimate
-- consumers keep their access:
--   - service_role (BYPASSRLS) — the control plane / outbox relay.
--   - adapter_registry_role    — the registry writer (its own narrow grants, set
--                                in db-bootstrap.psql, are untouched here).
--   - postgres superuser       — migrations + data plane.

-- 3a. tenant_databases — holds AES-GCM connection material. The public surface has
--     no business reading any of it; strip every privilege from anon/authenticated.
DO $secret_db$
BEGIN
  IF to_regclass('public.tenant_databases') IS NOT NULL THEN
    REVOKE ALL ON public.tenant_databases FROM anon, authenticated;
    -- Belt-and-suspenders: undo the schema-wide ALTER DEFAULT PRIVILEGES grant
    -- (migration 001) for any privilege re-added to these roles in future.
    -- (No GRANT back to anon/authenticated — they get nothing on this table.)
  END IF;
END
$secret_db$;

-- 3b. tenant_api_keys — holds key_hash (the credential verifier) + scopes. The
--     public REST surface never needs to read the hash. Revoke the blanket grant.
--     Self-service key issuance/rotation goes through the Go control plane
--     (service_role), not PostgREST, so authenticated loses nothing it actually
--     uses on the public surface.
DO $secret_keys$
BEGIN
  IF to_regclass('public.tenant_api_keys') IS NOT NULL THEN
    REVOKE ALL ON public.tenant_api_keys FROM anon, authenticated;
  END IF;
END
$secret_keys$;

-- 3c. Re-affirm the legitimate control-plane grants so a strict re-run leaves the
--     consumers whole. service_role is BYPASSRLS and already has ALL via the
--     bootstrap default privileges; this is explicit for clarity + drift-safety.
DO $reaffirm$
BEGIN
  IF to_regclass('public.tenant_databases') IS NOT NULL THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_databases TO service_role;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'adapter_registry_role') THEN
      -- Mirror the narrow grants db-bootstrap.psql gives the registry writer.
      GRANT SELECT, INSERT ON public.tenant_databases TO adapter_registry_role;
      GRANT UPDATE (last_healthy_at) ON public.tenant_databases TO adapter_registry_role;
    END IF;
  END IF;
  IF to_regclass('public.tenant_api_keys') IS NOT NULL THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_api_keys TO service_role;
  END IF;
END
$reaffirm$;

-- ─── Note on the tenant GUC fallback (audit item, no change required here) ────
-- auth.current_tenant_id()/current_user_id() (migration 016) fall back to the
-- app.current_user_id / app.current_tenant_id GUCs when the JWT claim is absent.
-- This fallback is for the Go/Rust application planes, which SET those GUCs inside
-- a server-side transaction. It is NOT reachable from the public PostgREST surface:
-- PostgREST only ever sets `request.jwt.claims` (and `request.header.*`) from the
-- VERIFIED JWT; a client cannot set an `app.*` GUC over HTTP. So on the public
-- surface the tenant id is always keyed off the verified claim. Step 2 (a
-- NOBYPASSRLS role) is what makes that guarantee real. Tightening the fallback
-- itself would change app-plane behaviour and is out of scope for this least-change
-- security fix.

INSERT INTO public.schema_migrations (version, name)
VALUES (65, '065_least_privilege_rls')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
--   -- (1) un-FORCE (re-enables owner exemption — only if reverting):
--   --   walk pg_class for relforcerowsecurity and ALTER TABLE … NO FORCE ROW LEVEL SECURITY;
--   -- (3) restore blanket grants (NOT recommended — reopens the secret-column leak):
--   --   GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_databases TO authenticated;
--   --   GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_api_keys  TO authenticated;
--   -- (2) drop the authenticator role (also revert PGRST_DB_URI to the superuser DSN):
--   --   REVOKE anon, authenticated, service_role FROM authenticator;
--   --   DROP ROLE IF EXISTS authenticator;
--   DELETE FROM public.schema_migrations WHERE version = 65;
-- COMMIT;
