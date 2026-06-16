-- File: scripts/migrations/postgresql/047_tenant_audit_log.sql
-- Migration 047: per-tenant tamper-evident audit log (Track-D D3).
--
-- ADDITIVE ONLY. Creates the durable HASH-CHAINED audit trail the flag-gated
-- tenant-facing audit API (TENANT_AUDIT_ENABLED, default OFF) appends to. Each
-- row is a link in a PER-TENANT chain:
--
--     hash = sha256( prev_hash || canonical(row) )
--
-- where canonical(row) is a deterministic, field-ordered serialization of the
-- semantic columns (tenant_id, seq, ts, actor, action, target, payload) computed
-- IN GO (engine-agnostic — the chain does not depend on any DB hashing function,
-- so the identical verify runs over rows exported from any engine). prev_hash of
-- the FIRST event for a tenant is the empty string; thereafter prev_hash is the
-- previous row's hash. A verifier recomputes the chain row-by-row and reports the
-- FIRST link whose stored hash != recomputed hash (a tampered payload, deleted
-- row, or re-ordered seq breaks the chain at exactly that link).
--
-- `seq` is the per-tenant monotonic position (1,2,3,…) — a UNIQUE(tenant_id, seq)
-- makes the order canonical and a hole detectable. The append path computes it as
-- (max(seq) for this tenant) + 1 under the SAME advisory-lock-or-tx the running
-- prev_hash read uses, so concurrent appends for one tenant cannot fork the chain.
--
-- ISOLATION: house RLS pattern (mirrors tenant_usage 040 / tenant_billing 041 /
-- tenant_backups 042): per-tenant isolation via auth.current_tenant_id(). The
-- control-plane audit service writes/reads as the BYPASSRLS service_role and
-- ALWAYS binds tenant_id in its WHERE (defense-in-depth), so a tenant can never
-- read OR verify another tenant's events even if RLS were misconfigured. No
-- UPDATE and no DELETE grant to authenticated: an audit row is append-only by
-- construction at the grant layer too (tamper-evidence is the whole point — the
-- only legitimate writer is the service role on the append path).
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With TENANT_AUDIT_ENABLED OFF (the default) the /v1/audit*
-- routes are never mounted, so nothing ever writes to this table, so it stays
-- empty = byte-parity baseline (same story as 040 / 041 / 042).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 47) THEN
    RAISE NOTICE 'Migration 047 already applied - skipping';
    RETURN;
  END IF;

  -- One row per audited event. `seq` is the per-tenant monotonic chain position;
  -- `prev_hash`/`hash` are the lower-hex sha256 chain links. `payload` is the
  -- event detail (jsonb); it participates in canonical(row) so any post-hoc edit
  -- of it breaks `hash`. `actor` is the principal that took the action
  -- (api-key:<uuid> / user:<id> / service / admin), `action` the verb
  -- (key.issue, plan.change, backup.create, …), `target` the affected object.
  CREATE TABLE IF NOT EXISTS public.tenant_audit_log (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  TEXT        NOT NULL,
    seq        BIGINT      NOT NULL,                 -- per-tenant monotonic chain position (1,2,3,…)
    ts         TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor      TEXT        NOT NULL DEFAULT '',      -- principal: api-key:<uuid> / user:<id> / service
    action     TEXT        NOT NULL,                 -- verb: key.issue / plan.change / backup.create / …
    target     TEXT        NOT NULL DEFAULT '',      -- affected object id / name
    payload    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    prev_hash  TEXT        NOT NULL DEFAULT '',      -- previous link's hash ('' for the first event)
    hash       TEXT        NOT NULL,                 -- sha256(prev_hash || canonical(row)), lower-hex
    -- the chain order is canonical and a hole is detectable: no two rows for a
    -- tenant may share a seq, and the verifier walks seq ASC.
    CONSTRAINT tenant_audit_log_tenant_seq_uniq UNIQUE (tenant_id, seq)
  );

  -- Query/verify scan by (tenant, seq ASC) — the chain walk order; the UNIQUE
  -- index above already covers (tenant_id, seq), so an extra index would be
  -- redundant. A ts index helps the query API's optional time-window filter.
  CREATE INDEX IF NOT EXISTS tenant_audit_log_tenant_ts_idx
    ON public.tenant_audit_log (tenant_id, ts);

  -- House RLS pattern (mirrors tenant_usage / tenant_billing / tenant_backups):
  -- per-tenant isolation via auth.current_tenant_id(). The control-plane audit
  -- service writes/reads as the BYPASSRLS service_role (unaffected); only
  -- anon/authenticated reads are scoped to their own tenant rows.
  ALTER TABLE public.tenant_audit_log ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'tenant_audit_log'
         AND policyname = 'tenant_audit_log_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_audit_log_tenant_isolation ON public.tenant_audit_log
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- Append-only at the grant layer too: the ONLY legitimate writer is the
  -- BYPASSRLS service role on the append path. authenticated gets SELECT only —
  -- no INSERT/UPDATE/DELETE — so a tenant can read+verify its own chain but can
  -- never forge, mutate, or delete a link. (service_role is BYPASSRLS but we
  -- re-affirm its write grants explicitly, the 001 blanket-grant story / 042.)
  GRANT SELECT                 ON public.tenant_audit_log TO authenticated;
  GRANT SELECT, INSERT         ON public.tenant_audit_log TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (47, '047_tenant_audit_log')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.tenant_audit_log;
-- DELETE FROM public.schema_migrations WHERE version = 47;
-- COMMIT;
