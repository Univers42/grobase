-- File: scripts/migrations/postgresql/055_tenant_branches.sql
-- Migration 055: per-tenant DB BRANCHES ledger (Track-E DB branching).
--
-- ADDITIVE ONLY. Creates the durable record for the flag-gated DB BRANCHING API
-- (DB_BRANCHING_ENABLED, default OFF). A "branch" is an isolated schema-clone of a
-- schema_per_tenant mount — the parent's tables + a full row copy — that a tenant
-- can use for preview/staging (Supabase-parity "branches"). One row per branch a
-- tenant has created.
--
-- Unlike B6 backup (042, restore-oriented COPY artifact) or D4.3 export (052,
-- portable JSON bundle), a branch is a LIVE, queryable schema sitting next to the
-- parent in the SAME control-plane Postgres: CREATE SCHEMA <branch_schema>, then
-- for each parent BASE TABLE `CREATE TABLE … (LIKE … INCLUDING ALL)` +
-- `INSERT … SELECT *`. The clone.go data path does this over the existing pgx pool
-- (NO pg_dump). The ledger here just records the branch (name, schema, counts,
-- status); dropping a branch DROPs its schema CASCADE and deletes the row.
--
-- The branching service INSERTs status='pending', UPDATEs to 'completed'/'failed'
-- once the clone lands. Rows are tenant-scoped via RLS exactly like tenant_usage
-- (040) / tenant_billing (041) / tenant_backups (042) / tenant_exports (052) —
-- owner-scoped reads for free, so a tenant can never even SEE another tenant's
-- branch row (the second safety wall under the load-bearing tenant_id bind the
-- service enforces on every query).
--
-- ISOLATION SCOPE: branching supports ONLY schema_per_tenant in the MVP (it clones
-- a schema). shared_rls (no per-tenant schema to clone) and db_per_tenant (needs a
-- DSN resolver, B6b-style) and tenant_owned (external DB) are DEFERRED; the CHECK
-- lists only schema_per_tenant, so a row for a deferred model cannot be inserted —
-- the deferral is enforced by the table itself, not just by service-layer code.
-- (The handler additionally returns 400 "isolation not supported for branching
-- (deferred)".)
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With DB_BRANCHING_ENABLED OFF (the default) the branch routes
-- are never mounted, so nothing ever writes to this table, so it stays empty =
-- byte-parity baseline (same story as 040 / 041 / 042 / 052).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 55) THEN
    RAISE NOTICE 'Migration 055 already applied - skipping';
    RETURN;
  END IF;

  -- One row per branch. `branch_schema` is the sanitized Postgres schema the
  -- clone lives in (e.g. tenant_<slug>_br_<name>); `parent_mount` is the mount
  -- name the branch was forked from (NULL = whole-tenant first mount).
  -- `table_count` / `row_count` are what the clone copied (the headline "N tables,
  -- M rows cloned" numbers). `status` tracks the lifecycle pending -> completed |
  -- failed. The isolation CHECK forbids deferred models structurally — only
  -- schema_per_tenant can be inserted.
  CREATE TABLE IF NOT EXISTS public.tenant_branches (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     TEXT        NOT NULL,
    parent_mount  TEXT,                 -- mount name the branch forked from; NULL = whole-tenant
    branch_name   TEXT        NOT NULL, -- caller-supplied label (validated to [a-z0-9_] by the service)
    branch_schema TEXT        NOT NULL, -- the sanitized Postgres schema the clone lives in
    isolation     TEXT        NOT NULL CHECK (isolation IN ('schema_per_tenant')),
    status        TEXT        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','completed','failed')),
    table_count   INTEGER     NOT NULL DEFAULT 0,
    row_count     BIGINT      NOT NULL DEFAULT 0,
    error_message TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at  TIMESTAMPTZ,
    -- One branch name per tenant (re-creating a dropped name is fine after the
    -- DROP deletes the row). The cross-tenant wall is tenant_id, never the name.
    UNIQUE (tenant_id, branch_name)
  );

  -- ListBranches scans by (tenant, most-recent-first): SELECT ... WHERE
  -- tenant_id=$1 ORDER BY created_at DESC.
  CREATE INDEX IF NOT EXISTS tenant_branches_tenant_created_idx
    ON public.tenant_branches (tenant_id, created_at DESC);

  -- House RLS pattern (mirrors tenant_usage / tenant_billing / tenant_backups /
  -- tenant_exports): per-tenant isolation via auth.current_tenant_id(). The
  -- control-plane branching service writes as the BYPASSRLS service_role, so admin
  -- writes are unaffected; only anon/authenticated reads are scoped to their own
  -- tenant rows.
  ALTER TABLE public.tenant_branches ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'tenant_branches'
         AND policyname = 'tenant_branches_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_branches_tenant_isolation ON public.tenant_branches
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- service_role is BYPASSRLS, but re-affirm the legitimate writer/reader grants
  -- explicitly (the 001 blanket-grant story; mirrors 040 / 041 / 042 / 052).
  -- DELETE is granted: dropping a branch deletes its ledger row (the branch
  -- lifecycle is two-directional, unlike a one-way export).
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_branches TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (55, '055_tenant_branches')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.tenant_branches;
-- DELETE FROM public.schema_migrations WHERE version = 55;
-- COMMIT;
