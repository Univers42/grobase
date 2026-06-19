-- ============================================
-- SCHEMA: Kanban configuration
-- ============================================

CREATE TABLE IF NOT EXISTS "KanbanColumn" (
    "id"            SERIAL PRIMARY KEY,
    "name"          VARCHAR(100) NOT NULL,
    "mapped_status" VARCHAR(30),
    "color"         VARCHAR(7),
    "position"      INT DEFAULT 0,
    "is_active"     BOOLEAN DEFAULT TRUE,
    "created_by"    INT REFERENCES "User"("id"),
    "created_at"    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS "OrderTag" (
    "id"         SERIAL PRIMARY KEY,
    "label"      VARCHAR(50) UNIQUE NOT NULL,
    "color"      VARCHAR(7),
    "created_by" INT REFERENCES "User"("id")
);

CREATE TABLE IF NOT EXISTS "OrderOrderTag" (
    "order_id" INT NOT NULL REFERENCES "Order"("id") ON DELETE CASCADE,
    "tag_id"   INT NOT NULL REFERENCES "OrderTag"("id") ON DELETE CASCADE,
    PRIMARY KEY ("order_id", "tag_id")
);
