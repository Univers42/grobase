-- 035_widen_tenant_plan_check.sql
--
-- Widen the tenants.plan CHECK to the current package manifest
-- (config/packages/packages.json). Migration 005 fixed the constraint at
-- ('free','pro','enterprise') — the pre-tiering plan names — so once tiering
-- shipped, assigning a tenant the real tier keys (nano/basic/essential/max)
-- failed with `violates check constraint "tenants_plan_check"` (SQLSTATE
-- 23514) and PACKAGE_ENFORCEMENT could not actually be exercised. The manifest
-- always assumed this additive migration would land (see its _aliases_comment).
--
-- Additive + idempotent: existing free/pro/enterprise rows stay valid; no data
-- is rewritten. The legacy aliases (free, enterprise) are KEPT in the allowlist
-- because packages.For() still maps them (free→nano, enterprise→max), so old
-- rows and old callers keep working.

BEGIN;

ALTER TABLE public.tenants DROP CONSTRAINT IF EXISTS tenants_plan_check;
ALTER TABLE public.tenants ADD CONSTRAINT tenants_plan_check
  CHECK (plan IN ('nano', 'basic', 'essential', 'pro', 'max', 'free', 'enterprise'));

INSERT INTO public.schema_migrations (version, name)
  VALUES (35, '035_widen_tenant_plan_check')
  ON CONFLICT (version) DO NOTHING;

COMMIT;

-- DOWN (manual, gated — only safe if no tenant uses a new-tier plan):
-- BEGIN;
-- ALTER TABLE public.tenants DROP CONSTRAINT IF EXISTS tenants_plan_check;
-- ALTER TABLE public.tenants ADD CONSTRAINT tenants_plan_check
--   CHECK (plan IN ('free', 'pro', 'enterprise'));
-- DELETE FROM public.schema_migrations WHERE version = 35;
-- COMMIT;
