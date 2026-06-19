-- Revoke ALL privileges from anon/authenticated on materialized views
REVOKE ALL ON "mv_orders_by_status" FROM anon, authenticated;
REVOKE ALL ON "mv_monthly_revenue"  FROM anon, authenticated;

-- Verify
SELECT relname AS matview, relacl
FROM pg_class
WHERE relname IN ('mv_orders_by_status', 'mv_monthly_revenue')
  AND relkind = 'm';
