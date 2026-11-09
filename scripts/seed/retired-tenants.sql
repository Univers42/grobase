-- retired-tenants.sql: what the seed still holds and the platform no longer has. Runs as the
-- last step of a restore, so it has to be safe to repeat and to find nothing.
--
-- Vite Gourmand, destroyed on 2026-11-04 by its owner's decision. Its mount's key was already
-- lost; the seed in vault42 is left as it is, so its tenant, its three personal tenants, their
-- accounts and its database come back with every restore and leave again here. All cascades
-- from these rows: apps, environments, groups, grants, projects, API keys.
BEGIN;
DELETE FROM public.tenant_databases WHERE tenant_id = 'gourmand';
DELETE FROM public.tenants WHERE slug = 'gourmand' OR name LIKE '%@gourmand.local';
DELETE FROM auth.users WHERE email LIKE '%@gourmand.local';
COMMIT;

-- Outside the transaction: a database cannot be dropped inside one.
DROP DATABASE IF EXISTS gourmand WITH (FORCE);
