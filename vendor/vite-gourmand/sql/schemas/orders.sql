-- ============================================
-- SCHEMA: Order lifecycle
-- ============================================

CREATE TABLE IF NOT EXISTS "Order" (
    "id"                        SERIAL PRIMARY KEY,
    "order_number"              VARCHAR(50) UNIQUE NOT NULL,
    "user_id"                   INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "order_date"                TIMESTAMPTZ DEFAULT NOW(),
    "delivery_date"             DATE NOT NULL,
    "delivery_hour"             VARCHAR(10),
    "delivery_address"          TEXT,
    "delivery_city"             VARCHAR(100) DEFAULT 'Bordeaux',
    "delivery_distance_km"      DECIMAL(10,2) DEFAULT 0,
    "person_number"             INT NOT NULL,
    "menu_price"                DECIMAL(10,2) NOT NULL,
    "delivery_price"            DECIMAL(10,2) DEFAULT 0,
    "discount_id"               INT REFERENCES "Discount"("id") ON DELETE SET NULL,
    "discount_percent"          DECIMAL(5,2) DEFAULT 0,
    "discount_amount"           DECIMAL(10,2) DEFAULT 0,
    "total_price"               DECIMAL(10,2) NOT NULL,
    "status"                    VARCHAR(30) DEFAULT 'pending',
    "material_lending"          BOOLEAN DEFAULT FALSE,
    "material_returned"         BOOLEAN DEFAULT FALSE,
    "material_return_deadline"  TIMESTAMPTZ,
    "cancellation_reason"       TEXT,
    "cancellation_contact_mode" VARCHAR(20),
    "special_instructions"      TEXT,
    "confirmed_at"              TIMESTAMPTZ,
    "delivered_at"              TIMESTAMPTZ,
    "cancelled_at"              TIMESTAMPTZ,
    "created_at"                TIMESTAMPTZ DEFAULT NOW(),
    "updated_at"                TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_order_user_date ON "Order"("user_id", "order_date" DESC);
CREATE INDEX IF NOT EXISTS idx_order_status ON "Order"("status");
CREATE INDEX IF NOT EXISTS idx_order_number ON "Order"("order_number");
CREATE INDEX IF NOT EXISTS idx_order_delivery ON "Order"("delivery_date");

-- ============================================
-- Junction: Order <-> Menu (M:N)
-- An order can contain multiple menus.
-- A menu can appear in multiple orders.
-- ============================================
CREATE TABLE IF NOT EXISTS "OrderMenu" (
    "order_id" INT NOT NULL REFERENCES "Order"("id") ON DELETE CASCADE,
    "menu_id"  INT NOT NULL REFERENCES "Menu"("id") ON DELETE CASCADE,
    "quantity"  INT DEFAULT 1,
    PRIMARY KEY ("order_id", "menu_id")
);

CREATE INDEX IF NOT EXISTS idx_order_menu_menu ON "OrderMenu"("menu_id");

-- ============================================
-- Order status history (audit trail)
-- ============================================
CREATE TABLE IF NOT EXISTS "OrderStatusHistory" (
    "id"         SERIAL PRIMARY KEY,
    "order_id"   INT NOT NULL REFERENCES "Order"("id") ON DELETE CASCADE,
    "old_status" VARCHAR(30),
    "new_status" VARCHAR(30) NOT NULL,
    "notes"      TEXT,
    "changed_at" TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_osh_order ON "OrderStatusHistory"("order_id");

-- ============================================
-- Delivery assignment
-- ============================================
CREATE TABLE IF NOT EXISTS "DeliveryAssignment" (
    "id"                 SERIAL PRIMARY KEY,
    "order_id"           INT NOT NULL REFERENCES "Order"("id") ON DELETE CASCADE,
    "delivery_person_id" INT REFERENCES "User"("id"),
    "vehicle_type"       VARCHAR(50),
    "status"             VARCHAR(20) DEFAULT 'assigned',
    "assigned_at"        TIMESTAMPTZ DEFAULT NOW(),
    "picked_up_at"       TIMESTAMPTZ,
    "delivered_at"       TIMESTAMPTZ,
    "delivery_notes"     TEXT,
    "proof_photo_url"    VARCHAR(500),
    "client_rating"      INT CHECK ("client_rating" BETWEEN 1 AND 5)
);

-- NOTE: Discount is defined in loyalty.sql (loaded before this file).
-- LoyaltyAccount & LoyaltyTransaction are in loyalty_post_order.sql (loaded after).
