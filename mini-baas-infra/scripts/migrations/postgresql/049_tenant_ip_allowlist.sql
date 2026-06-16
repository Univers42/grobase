-- File: scripts/migrations/postgresql/049_tenant_ip_allowlist.sql
-- Migration 049: per-tenant API IP allowlist (Track-D D2e).
--
-- ADDITIVE ONLY. Creates the durable table the flag-gated edge IP-allowlist
-- guard (TENANT_IP_ALLOWLIST_ENABLED, default OFF) reads when deciding whether a
-- request's client IP may reach a tenant's API:
--
--   public.tenant_ip_allowlist : zero-or-more CIDR rules per tenant. A tenant
--                                with NO row here is UNRESTRICTED (the guard
--                                allows any client IP) — the feature is OPT-IN.
--                                A tenant WITH ≥1 row is restricted to the union
--                                of its CIDRs; a request whose source IP is in
--                                none of them is rejected (403) at the edge.
--
-- The "no row = open, ≥1 row = closed-to-the-union" default is the SAME safe
-- opt-in shape tenant_billing uses (no row = not billed): adding the table to a
-- live database changes nothing until a tenant ADDS a rule AND the operator
-- flips TENANT_IP_ALLOWLIST_ENABLED on. Running this migration changes NO
-- existing behavior (no ALTER/DROP of any existing object). With the flag OFF
-- (the default) the guard never consults this table, so it stays inert =
-- byte-parity baseline (same story as 040/041/042/047).
--
-- `cidr` uses Postgres's native CIDR type so a malformed network is rejected by
-- the DB at write time (defence in depth — the control-plane handler also
-- validates), and so a containment test can be expressed as `$ip <<= cidr` if a
-- future operator wants an in-DB check. The control-plane guard does the
-- containment match IN GO (net.ParseCIDR + Contains), engine-agnostic and
-- independent of any DB inet operator, exactly as the audit chain hashes in Go.
--
-- ISOLATION: house RLS pattern (mirrors tenant_usage 040 / tenant_billing 041 /
-- tenant_backups 042 / tenant_audit_log 047): per-tenant isolation via
-- auth.current_tenant_id(). The control-plane guard/CRUD service writes/reads as
-- the BYPASSRLS service_role and ALWAYS binds tenant_id in its WHERE
-- (defence-in-depth), so a tenant can never read OR mutate another tenant's
-- allowlist even if RLS were misconfigured.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 49) THEN
    RAISE NOTICE 'Migration 049 already applied - skipping';
    RETURN;
  END IF;

  -- One row per allow rule. (tenant_id, cidr) is unique so a re-add of the same
  -- rule is idempotent (the CRUD upsert relies on it). `note` is an optional
  -- human label ("office VPN", "CI runners"). `created_by` records the principal
  -- that added the rule (api-key:<uuid> / user:<id> / admin) for the audit trail.
  CREATE TABLE IF NOT EXISTS public.tenant_ip_allowlist (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   TEXT        NOT NULL,
    cidr        CIDR        NOT NULL,                  -- native CIDR: a malformed network is rejected at write time
    note        TEXT        NOT NULL DEFAULT '',       -- optional human label
    created_by  TEXT        NOT NULL DEFAULT '',       -- principal: api-key:<uuid> / user:<id> / admin
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- a rule is unique per tenant: adding "10.0.0.0/8" twice is a no-op upsert,
    -- never a duplicate row that would double the guard's scan.
    CONSTRAINT tenant_ip_allowlist_tenant_cidr_uniq UNIQUE (tenant_id, cidr)
  );

  -- The guard's hot path is "all CIDRs for THIS tenant" — a tenant-scoped index
  -- keeps that O(rules-for-tenant), not O(all-rules). The UNIQUE above already
  -- covers (tenant_id, cidr); this btree on tenant_id alone serves the bare
  -- "list my rules" scan the guard runs on every request for a restricted tenant.
  CREATE INDEX IF NOT EXISTS tenant_ip_allowlist_tenant_idx
    ON public.tenant_ip_allowlist (tenant_id);

  -- House RLS pattern (mirrors tenant_usage / tenant_billing / tenant_backups /
  -- tenant_audit_log): per-tenant isolation via auth.current_tenant_id(). The
  -- control-plane guard reads/writes as the BYPASSRLS service_role (unaffected);
  -- only anon/authenticated reads are scoped to their own tenant rows.
  ALTER TABLE public.tenant_ip_allowlist ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
       WHERE schemaname = 'public' AND tablename = 'tenant_ip_allowlist'
         AND policyname = 'tenant_ip_allowlist_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_ip_allowlist_tenant_isolation ON public.tenant_ip_allowlist
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- A tenant may read+manage its OWN allowlist via the self-serve API
  -- (authenticated → SELECT/INSERT/DELETE its own rows under RLS); the BYPASSRLS
  -- service_role does the privileged guard read on the request path. We re-affirm
  -- service_role's grants explicitly (the 001 blanket-grant story / 042).
  GRANT SELECT, INSERT, DELETE ON public.tenant_ip_allowlist TO authenticated;
  GRANT SELECT, INSERT, DELETE ON public.tenant_ip_allowlist TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (49, '049_tenant_ip_allowlist')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.tenant_ip_allowlist;
-- DELETE FROM public.schema_migrations WHERE version = 49;
-- COMMIT;
