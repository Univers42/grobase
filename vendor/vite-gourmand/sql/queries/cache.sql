-- ============================================
-- CACHE & DASHBOARD QUERIES
-- ============================================

-- Quick dashboard stats from materialized view
SELECT "status", "count", "total_revenue" FROM "mv_orders_by_status";

-- Monthly revenue trend
SELECT "month", "order_count", "revenue", "avg_order_value" FROM "mv_monthly_revenue" LIMIT 12;

-- Low stock alert
SELECT "id", "name", "unit", "current_stock", "min_stock_level" FROM "v_low_stock_ingredients";

-- Active menus (cached view)
SELECT
  "id",
  "title",
  "description",
  "conditions",
  "person_min",
  "price_per_person",
  "remaining_qty",
  "status",
  "diet_id",
  "theme_id",
  "created_by",
  "is_seasonal",
  "available_from",
  "available_until",
  "created_at",
  "updated_at",
  "published_at",
  "diet_name",
  "theme_name"
FROM "v_active_menus";

-- Pending reviews count (quick badge)
SELECT COUNT(*) AS "pending_reviews" FROM "v_pending_reviews";

-- Upcoming deliveries this week
SELECT
    "delivery_date",
    COUNT(*) AS "orders",
    SUM("person_number") AS "total_persons"
FROM "Order"
WHERE "delivery_date" BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days'
  AND "status" NOT IN ('cancelled', 'completed')
GROUP BY "delivery_date"
ORDER BY "delivery_date";
