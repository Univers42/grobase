-- ============================================
-- SCHEMA: Discounts (pre-Order dependency)
-- ============================================
-- NOTE: This file MUST be loaded BEFORE orders.sql
-- because Order.discount_id references Discount.id.
--
-- LoyaltyAccount and LoyaltyTransaction live in
-- loyalty_post_order.sql (loaded AFTER orders.sql)
-- because LoyaltyTransaction.order_id → Order.id.
-- ============================================

-- Discount MUST exist before Order (FK dependency)
CREATE TABLE IF NOT EXISTS "Discount" (
    "id"               SERIAL PRIMARY KEY,
    "code"             VARCHAR(50) UNIQUE NOT NULL,
    "description"      TEXT,
    "type"             VARCHAR(20) NOT NULL CHECK ("type" IN ('percentage', 'fixed_amount')),
    "value"            DECIMAL(10,2) NOT NULL CHECK ("value" > 0),
    "min_order_amount" DECIMAL(10,2),
    "max_uses"         INT,
    "current_uses"     INT DEFAULT 0,
    "valid_from"       DATE,
    "valid_until"      DATE,
    "is_active"        BOOLEAN DEFAULT TRUE,
    "created_by"       INT REFERENCES "User"("id")
);
