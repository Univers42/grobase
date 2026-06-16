-- File: scripts/migrations/postgresql/052_tenant_exports.sql
-- Migration 052: per-tenant data-export ledger (Track-D D4.3, GDPR portability).
--
-- ADDITIVE ONLY. Creates the durable record for the flag-gated per-tenant data
-- EXPORT API (TENANT_EXPORT_ENABLED, default OFF). One row per portable bundle a
-- tenant has produced. Unlike B6 backup (042), which is RESTORE-oriented (a COPY
-- artifact replayed back into the SAME platform), a D4.3 export is a PORTABLE
-- bundle (per-table JSON, plus a manifest{tables, counts, sha256}) the tenant can
-- carry to ANOTHER system — GDPR Art. 20 data portability.
--
-- The control-plane export service INSERTs status='pending', UPDATEs to
-- 'completed'/'failed' once the bundle lands; there is no restore lifecycle (a
-- portable bundle is one-directional). Rows are tenant-scoped via RLS exactly
-- like tenant_usage (040) / tenant_billing (041) / tenant_backups (042) /
-- tenant_audit_log (047) — owner-scoped reads for free, so a tenant can never
-- even SEE another tenant's export row (the second safety wall under the
-- load-bearing caller==owner check the service enforces).
--
-- ISOLATION SCOPE: an export supports the two tenant-resolvable isolation models
-- D4.4 erase already resolves — schema_per_tenant (that schema's BASE TABLEs)
-- and shared_rls (the shared data tables, WHERE tenant_id). The CHECK lists both.
-- db_per_tenant (needs the DSN resolver, B6b-style) and tenant_owned (external
-- DB) are DEFERRED; a row for either cannot be inserted, so the deferral is
-- enforced by the table itself, not just by service-layer code. (The handler
-- additionally returns 400 "isolation not supported for export (deferred)".)
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With TENANT_EXPORT_ENABLED OFF (the default) the export
-- routes are never mounted, so nothing ever writes to this table, so it stays
-- empty = byte-parity baseline (same story as 040 / 041 / 042 / 047).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 52) THEN
    RAISE NOTICE 'Migration 052 already applied - skipping';
    RETURN;
  END IF;

  -- One row per portable export bundle. `manifest` is the JSON manifest
  -- {tables:[{table,rows,format}], row_count, sha256} the service computes from
  -- the bundle it produced (the same sha256 the bundle's own manifest footer
  -- carries, so a downstream verifier can match the ledger to the file).
  -- `row_count` is the total rows across all exported tables (the headline GDPR
  -- "you got N records" number); `table_count` the number of tables. `location`
  -- is the ArtifactStore key (a filesystem path or s3://). `status` tracks the
  -- lifecycle pending -> completed | failed. The isolation CHECK forbids
  -- deferred models structurally.
  CREATE TABLE IF NOT EXISTS public.tenant_exports (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     TEXT        NOT NULL,
    mount         TEXT,                 -- mount name / mount_id for context; NULL = whole-tenant
    isolation     TEXT        NOT NULL CHECK (isolation IN ('schema_per_tenant','shared_rls')),
    engine        TEXT        NOT NULL DEFAULT 'postgresql',
    format        TEXT        NOT NULL DEFAULT 'json'
                  CHECK (format IN ('json','csv')),
    location      TEXT        NOT NULL, -- artifact key (fs path or s3://baas/exports/{tenant}/{id})
    table_count   INTEGER     NOT NULL DEFAULT 0,
    row_count     BIGINT      NOT NULL DEFAULT 0,
    size_bytes    BIGINT      NOT NULL DEFAULT 0,
    sha256        TEXT,                 -- bundle content hash (integrity / portability proof)
    manifest      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    status        TEXT        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','completed','failed')),
    error_message TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at  TIMESTAMPTZ
  );

  -- ListExports scans by (tenant, most-recent-first): SELECT ... WHERE
  -- tenant_id=$1 ORDER BY created_at DESC.
  CREATE INDEX IF NOT EXISTS tenant_exports_tenant_created_idx
    ON public.tenant_exports (tenant_id, created_at DESC);

  -- House RLS pattern (mirrors tenant_usage / tenant_billing / tenant_backups /
  -- tenant_audit_log): per-tenant isolation via auth.current_tenant_id(). The
  -- control-plane export service writes as the BYPASSRLS service_role, so admin
  -- writes are unaffected; only anon/authenticated self-serve reads are scoped to
  -- their own tenant rows -> the read-only /v1/tenants/me/exports surface is
  -- tenant-scoped for free.
  ALTER TABLE public.tenant_exports ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'tenant_exports'
         AND policyname = 'tenant_exports_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_exports_tenant_isolation ON public.tenant_exports
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- service_role is BYPASSRLS, but re-affirm the legitimate writer/reader grants
  -- explicitly (the 001 blanket-grant story; mirrors 040 / 041 / 042). No DELETE
  -- grant in MVP: cross-tenant delete is blocked by RLS and retention GC is
  -- deferred.
  GRANT SELECT, INSERT, UPDATE ON public.tenant_exports TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (52, '052_tenant_exports')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.tenant_exports;
-- DELETE FROM public.schema_migrations WHERE version = 52;
-- COMMIT;
