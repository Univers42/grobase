-- detect-forged-tenants.sql: read-only check for rows forged through the N-36 REST path.
--
-- Before migration 090 any signed-up user could INSERT a tenants row whose id is their own
-- GoTrue uuid, then tenant-keyed control rows with tenant_id = that uuid. A legitimate
-- tenant id is never a user's uuid (033 and tenant-control let the column default pick it),
-- so any match below is a forgery. 090 stops new ones; it does not remove old ones.
-- Run on every deployment that served /rest/v1 before 090:
--   docker exec -i mini-baas-postgres psql -U postgres -d postgres -q < scripts/security/detect-forged-tenants.sql
-- Prints one NOTICE per affected table, then "forged rows: N". N > 0: inspect, then delete
-- the listed rows (and the forger's tenant) as the owner.
-- Ponytail: only the id = user-uuid signature is detected; a forged row that reused a real
-- tenant's id could not pass the old policies, so it is not searched for.
DO $$
DECLARE
  r record;
  n bigint;
  total bigint;
BEGIN
  SELECT count(*) INTO total FROM public.tenants t JOIN auth.users u ON u.id::text = t.id::text;
  IF total > 0 THEN
    RAISE NOTICE 'public.tenants: % row(s) whose id is a user uuid', total;
  END IF;
  FOR r IN
    SELECT DISTINCT c.oid::regclass AS rel
      FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid AND c.relnamespace = 'public'::regnamespace
      JOIN pg_depend d ON d.classid = 'pg_policy'::regclass AND d.objid = pol.oid
                      AND d.refclassid = 'pg_proc'::regclass
      JOIN pg_proc f ON f.oid = d.refobjid AND f.proname = 'current_tenant_id'
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
  LOOP
    EXECUTE format('SELECT count(*) FROM %s x WHERE x.tenant_id::text IN (SELECT id::text FROM auth.users)', r.rel)
      INTO n;
    IF n > 0 THEN
      RAISE NOTICE '%: % row(s) whose tenant_id is a user uuid', r.rel, n;
    END IF;
    total := total + n;
  END LOOP;
  RAISE NOTICE 'forged rows: %', total;
END
$$;
