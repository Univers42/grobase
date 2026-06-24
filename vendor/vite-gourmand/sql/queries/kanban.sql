-- ============================================
-- KANBAN & ORDER TAG QUERIES
-- ============================================

-- Get kanban columns (board layout)
SELECT "id", "name", "mapped_status", "color", "position"
FROM "KanbanColumn"
WHERE "is_active"
ORDER BY "position" ASC;

-- Get orders for a specific kanban column
SELECT
    "o"."id", "o"."order_number", "o"."delivery_date", "o"."total_price",
    "u"."first_name" || ' ' || "u"."last_name" AS "client"
FROM "Order" AS "o"
JOIN "User" AS "u" ON "o"."user_id" = "u"."id"
WHERE "o"."status" = 'pending'  -- $1: mapped_status
ORDER BY "o"."delivery_date" ASC;

-- Get tags for an order
SELECT "ot"."label", "ot"."color"
FROM "OrderOrderTag" AS "oot"
JOIN "OrderTag" AS "ot" ON "oot"."tag_id" = "ot"."id"
WHERE "oot"."order_id" = 1;

-- Add tag to order
INSERT INTO "OrderOrderTag" ("order_id", "tag_id")
VALUES (4, (SELECT "id" FROM "OrderTag" WHERE "label" = 'urgent'))
ON CONFLICT DO NOTHING;

-- Remove tag from order
DELETE FROM "OrderOrderTag"
WHERE "order_id" = 1 AND "tag_id" = (SELECT "id" FROM "OrderTag" WHERE "label" = 'vip');
