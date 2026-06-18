-- File: scripts/migrations/postgresql/042_tenant_backups.sql
-- Migration 042: per-tenant backup/restore ledger (Track-B B6).
--
-- ADDITIVE ONLY. Creates the durable record for the flag-gated per-tenant
-- backup/restore API (TENANT_BACKUP_ENABLED, default OFF). One row per backup
-- artifact a tenant has produced via Go-native logical export (COPY ... TO
-- STDOUT) into an ArtifactStore (local-fs default, MinIO in production). The
-- control-plane backup service INSERTs status='pending', UPDATEs to
-- 'completed'/'failed' once the artifact lands; a restore flips it through
-- 'restoring'->'restored'. Rows are tenant-scoped via RLS exactly like
-- tenant_usage (040) and tenant_billing (041) — owner-scoped reads for free so
-- a tenant can never even SEE another tenant's backup row (the second safety
-- wall under the load-bearing caller==owner check the service enforces before
-- any DDL).
--
-- ISOLATION SCOPE (structural deferral): the CHECK on `isolation` lists ONLY the
-- MVP-clean model schema_per_tenant. db_per_tenant is DEFERRED to B6b (the
-- extract/restore code paths exist but the DSN resolver is not yet wired and the
-- round-trip is not yet gate-proven — we don't advertise unproven support).
-- shared_rls (would need a filtered dump + upsert into a LIVE shared table —
-- never TRUNCATE a shared object) and tenant_owned (external DB) are deferred
-- too; a row for any deferred model cannot even be inserted, so the deferral is
-- enforced by the table itself, not just by service-layer code.
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With TENANT_BACKUP_ENABLED OFF (the default) the backup
-- routes are never mounted, so nothing ever writes to this table, so it stays
-- empty = byte-parity baseline (same story as 040 / 041).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 42) THEN
    RAISE NOTICE 'Migration 042 already applied - skipping';
    RETURN;
  END IF;

  -- One row per backup artifact. `mount` is the mount name / mount_id for
  -- context (NULL = whole-tenant). `location` is the ArtifactStore key (a
  -- filesystem path or s3://baas/backups/{tenant}/{id}); `sha256` is the
  -- artifact content hash for integrity verification on restore. `status`
  -- tracks the lifecycle pending -> completed | failed, then restoring ->
  -- restored. The isolation CHECK forbids deferred models structurally.
  CREATE TABLE IF NOT EXISTS public.tenant_backups (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     TEXT        NOT NULL,
    mount         TEXT,                 -- mount name / mount_id for context; NULL = whole-tenant
    isolation     TEXT        NOT NULL CHECK (isolation IN ('schema_per_tenant')),
    engine        TEXT        NOT NULL DEFAULT 'postgresql',
    location      TEXT        NOT NULL, -- artifact key (fs path or s3://baas/backups/{tenant}/{id})
    size_bytes    BIGINT      NOT NULL DEFAULT 0,
    sha256        TEXT,                 -- artifact content hash (integrity)
    status        TEXT        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','completed','failed','restoring','restored')),
    error_message TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at  TIMESTAMPTZ
  );

  -- ListBackups scans by (tenant, most-recent-first): SELECT ... WHERE
  -- tenant_id=$1 ORDER BY created_at DESC.
  CREATE INDEX IF NOT EXISTS tenant_backups_tenant_created_idx
    ON public.tenant_backups (tenant_id, created_at DESC);

  -- House RLS pattern (mirrors tenant_usage / tenant_billing): per-tenant
  -- isolation via auth.current_tenant_id(). The control-plane backup service
  -- writes as the BYPASSRLS service_role, so admin writes are unaffected; only
  -- anon/authenticated self-serve reads are scoped to their own tenant rows ->
  -- the read-only /v1/tenants/me/backups surface is tenant-scoped for free.
  ALTER TABLE public.tenant_backups ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'tenant_backups'
         AND policyname = 'tenant_backups_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_backups_tenant_isolation ON public.tenant_backups
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- service_role is BYPASSRLS, but re-affirm the legitimate writer/reader grants
  -- explicitly (the 001 blanket-grant story; mirrors 040 / 041). No DELETE grant
  -- in MVP: cross-tenant delete is blocked by RLS and retention GC is deferred.
  GRANT SELECT, INSERT, UPDATE ON public.tenant_backups TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (42, '042_tenant_backups')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.tenant_backups;
-- DELETE FROM public.schema_migrations WHERE version = 42;
-- COMMIT;
