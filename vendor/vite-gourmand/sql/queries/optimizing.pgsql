-- ============================================
-- OPTIMIZATION & MAINTENANCE QUERIES
-- ============================================

-- Refresh cached reporting data (run via cron)
SELECT refresh_mv_orders_by_status();
SELECT refresh_mv_monthly_revenue();

-- Check index usage
SELECT
    schemaname, tablename, indexname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

-- Check table sizes
SELECT
    relname AS "table",
    pg_size_pretty(pg_total_relation_size(relid)) AS "total_size",
    pg_size_pretty(pg_relation_size(relid)) AS "data_size",
    n_live_tup AS "row_count"
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC;

-- Vacuum analyze (maintenance)
-- VACUUM ANALYZE "Order";
-- VACUUM ANALYZE "User";
-- VACUUM ANALYZE "Menu";

-- Check for dead tuples needing vacuum
SELECT
    relname, n_dead_tup, n_live_tup,
    ROUND(n_dead_tup::NUMERIC / NULLIF(n_live_tup, 0) * 100, 2) AS "dead_pct"
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC;