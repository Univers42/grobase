# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    062_tenant_entitlements.sql                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Migration 062: DYNAMIC BUILDER per-tenant entitlement store (BUILDER_ENABLED).
#
# ADDITIVE ONLY. Creates the durable state the flag-gated dynamic builder reads:
#
#   public.tenant_entitlements : ONE row per tenant (PK = tenant SLUG, matching
#                                tenant_usage.tenant_id / the public identity the
#                                data plane stamps), carrying
#                                  - entitlement JSONB : the per-tenant CUSTOM
#                                    overlay (narrowed engines/capabilities/limits/
#                                    mounts/addons) a tenant COMPOSES within its
#                                    ceiling, or an operator MINTS.
#                                  - ceiling_plan TEXT NULL : an OPERATOR-set
#                                    per-tenant ceiling above the tenant's named
#                                    plan (a sales deal). NULL = the tenant's own
#                                    plan IS the ceiling (the parity ceiling).
#                                  - status TEXT (active|draft) : only an ACTIVE
#                                    row applies at resolve time; a draft is parity
#                                    (resolves the named tier).
#                                A tenant with NO row resolves the named tier
#                                verbatim (manifest.For) — byte-parity.
#
# THE CEILING IS A PRIVILEGE BOUNDARY enforced in the CONTROL PLANE (Go), not in
# SQL: the entitlement JSON is CLAMPED to the ceiling package on EVERY resolve
# (entitlements.Resolver.Resolve → packages.Clamp), so even a stale over-ceiling
# row (operator set it high, tenant later downgraded) can NEVER widen the stamped
# capability_overrides / quota. The SQL here just stores the row durably; it is
# the resolve-time Clamp + the compose-time ValidateWithin that bound privilege.
#
# Running this migration changes NO existing behavior. With BUILDER_ENABLED OFF
# (the default) nothing ever reads or writes this table on any request path, so it
# stays empty = byte-parity baseline (the same story as 040/041/042/045). It
# mirrors the RLS + grant pattern of those migrations: per-tenant isolation for
# any tenant-facing read; the control-plane builder writes/reads as the BYPASSRLS
# service_role.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 62) THEN
    RAISE NOTICE 'Migration 062 already applied - skipping';
    RETURN;
  END IF;

  -- ── Dynamic builder per-tenant entitlement ─────────────────────────────────
  CREATE TABLE IF NOT EXISTS public.tenant_entitlements (
    tenant_id    TEXT        PRIMARY KEY,                 -- the tenant SLUG
    entitlement  JSONB       NOT NULL DEFAULT '{}'::jsonb, -- custom overlay (clamped at resolve time)
    ceiling_plan TEXT,                                    -- operator ceiling; NULL = use tenants.plan
    status       TEXT        NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','draft')),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
  );

  -- House RLS pattern (mirrors tenant_usage 040 / tenant_safety 045): per-tenant
  -- isolation via auth.current_tenant_id(). The control-plane builder writes/reads
  -- as the BYPASSRLS service_role, so it is unaffected; only an anon/authenticated
  -- self-serve read would be scoped to its own row. (The builder API resolves the
  -- tenant from the caller credential in Go, so this RLS is defense-in-depth.)
  ALTER TABLE public.tenant_entitlements ENABLE ROW LEVEL SECURITY;

  DO $pol$ BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename='tenant_entitlements' AND policyname='tenant_entitlements_tenant_isolation'
    ) THEN
      CREATE POLICY tenant_entitlements_tenant_isolation ON public.tenant_entitlements
        FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
        WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
    END IF;
  END $pol$;

  -- service_role is BYPASSRLS, but re-affirm the legitimate writer/reader grants
  -- explicitly (mirrors 040 / 041 / 042 / 045).
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_entitlements TO authenticated, service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (62, '062_tenant_entitlements')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

# DOWN (manual, gated):
# BEGIN;
# DROP TABLE IF EXISTS public.tenant_entitlements;
# DELETE FROM public.schema_migrations WHERE version = 62;
# COMMIT;
