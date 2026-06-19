-- ============================================
-- SCHEMA: Materialized views for dashboard
-- ============================================

CREATE MATERIALIZED VIEW IF NOT EXISTS "mv_orders_by_status" AS
SELECT
    "status",
    COUNT(*) AS "count",
    COALESCE(SUM("total_price"), 0) AS "total_revenue"
FROM "Order"
GROUP BY "status";

CREATE MATERIALIZED VIEW IF NOT EXISTS "mv_monthly_revenue" AS
SELECT
    DATE_TRUNC('month', "order_date") AS "month",
    COUNT(*) AS "order_count",
    COALESCE(SUM("total_price"), 0) AS "revenue",
    COALESCE(AVG("total_price"), 0) AS "avg_order_value"
FROM "Order"
WHERE "status" NOT IN ('cancelled')
GROUP BY DATE_TRUNC('month', "order_date")
ORDER BY "month" DESC;
