-- File: scripts/migrations/postgresql/048_tenant_erasure.sql
-- Migration 048: per-tenant HARD-ERASE / teardown ledger (Track-D D4.4).
--
-- ADDITIVE ONLY. Creates the durable record for the flag-gated PROVABLE
-- destruction of a tenant's data (HARD_ERASE_ENABLED, default OFF). Today a
-- tenant teardown is SOFT-DELETE only (tenants.status='deleted' — the rows stay,
-- recoverable). D4.4 adds a hard-erase that PROVABLY destroys the tenant's data:
--   - schema_per_tenant => DROP SCHEMA <tenant_schema> CASCADE (the whole schema
--     and every object in it ceases to exist),
--   - shared_rls        => DELETE FROM the tenant's tables WHERE tenant matches
--     (a TRUNCATE would wipe every tenant's rows in a shared table — never that),
--   - the tenant's API keys are revoked/deleted so no credential authenticates,
--   - storage objects are best-effort + DOCUMENTED (the control-plane DB has no
--     authority over an external object store; the receipt records the intent).
-- It then writes BOTH a tamper-evident D3 audit receipt (audit.Append onto the
-- per-tenant hash chain — proof the erase HAPPENED that survives the data going
-- away) AND one row here recording the purge (who/when/scope/rows_purged/the
-- audit chain seq the receipt sealed at).
--
-- One row per erase request. `scope` is the isolation model that drove the
-- destruction (schema_per_tenant | shared_rls). `rows_purged` is the count of
-- rows actually destroyed (schema drop reports the pre-drop row total across the
-- schema's tables; shared_rls reports the DELETEd row total). `audit_seq` is the
-- seq of the D3 audit-log link the erase receipt sealed at — it cross-links the
-- ledger row to the tamper-evident chain so the two corroborate each other.
--
-- ISOLATION: house RLS pattern (mirrors tenant_usage 040 / tenant_billing 041 /
-- tenant_backups 042 / tenant_audit_log 047): per-tenant isolation via
-- auth.current_tenant_id(). The control-plane erase service writes/reads as the
-- BYPASSRLS service_role and ALWAYS binds tenant_id in its WHERE
-- (defense-in-depth). No UPDATE/DELETE grant to authenticated: an erasure
-- receipt is an append-only forensic record (an erase that could be un-recorded
-- defeats the audit purpose); the only legitimate writer is the service role on
-- the erase path.
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With HARD_ERASE_ENABLED OFF (the default) the /v1/tenants/
-- {id}/erase route is never mounted, so nothing ever writes to this table and no
-- destruction ever runs — byte-identical to today's soft-delete-only baseline
-- (same story as 040 / 041 / 042 / 047).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 48) THEN
    RAISE NOTICE 'Migration 048 already applied - skipping';
    RETURN;
  END IF;

  -- One row per hard-erase request. `requested_by` is the principal that asked
  -- for the teardown (admin / service / user:<id>); `requested_at` /
  -- `completed_at` bracket the destruction. `scope` is the isolation model that
  -- drove it; `rows_purged` counts the destroyed rows; `audit_seq` cross-links
  -- to the D3 tamper-evident receipt (the seq the erase link sealed at). `status`
  -- tracks pending -> completed | failed.
  CREATE TABLE IF NOT EXISTS public.erasure_receipts (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     TEXT        NOT NULL,
    requested_by  TEXT        NOT NULL DEFAULT '',    -- principal: admin / service / user:<id>
    requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at  TIMESTAMPTZ,
    scope         TEXT        NOT NULL                -- isolation model that drove destruction
                  CHECK (scope IN ('schema_per_tenant','shared_rls')),
    rows_purged   BIGINT      NOT NULL DEFAULT 0,     -- rows actually destroyed
    keys_revoked  BIGINT      NOT NULL DEFAULT 0,     -- API keys revoked/deleted
    audit_seq     BIGINT,                             -- D3 audit-log seq the receipt sealed at
    status        TEXT        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','completed','failed')),
    error_message TEXT
  );

  -- A tenant's erase history scans by (tenant, most-recent-first).
  CREATE INDEX IF NOT EXISTS erasure_receipts_tenant_requested_idx
    ON public.erasure_receipts (tenant_id, requested_at DESC);

  -- House RLS pattern (mirrors tenant_usage / tenant_billing / tenant_backups /
  -- tenant_audit_log): per-tenant isolation via auth.current_tenant_id(). The
  -- control-plane erase service writes/reads as the BYPASSRLS service_role
  -- (unaffected); only anon/authenticated reads are scoped to their own rows.
  ALTER TABLE public.erasure_receipts ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'erasure_receipts'
         AND policyname = 'erasure_receipts_tenant_isolation'
    ) THEN
      CREATE POLICY erasure_receipts_tenant_isolation ON public.erasure_receipts
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- Append-only forensic record at the grant layer too: authenticated gets
  -- SELECT only (read your own erase history), never INSERT/UPDATE/DELETE. The
  -- only legitimate writer is the BYPASSRLS service role on the erase path.
  -- (service_role is BYPASSRLS but we re-affirm its write grants explicitly,
  -- the 001 blanket-grant story / 042 / 047.)
  GRANT SELECT                 ON public.erasure_receipts TO authenticated;
  GRANT SELECT, INSERT, UPDATE ON public.erasure_receipts TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (48, '048_tenant_erasure')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.erasure_receipts;
-- DELETE FROM public.schema_migrations WHERE version = 48;
-- COMMIT;
