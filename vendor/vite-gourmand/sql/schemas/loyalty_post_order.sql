-- ============================================
-- SCHEMA: Loyalty Accounts & Transactions
-- ============================================
-- MUST be loaded AFTER orders.sql because
-- LoyaltyTransaction.order_id → Order.id
-- ============================================

CREATE TABLE IF NOT EXISTS "LoyaltyAccount" (
    "id"               SERIAL PRIMARY KEY,
    "user_id"          INT UNIQUE NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "total_earned"     INT DEFAULT 0 CHECK ("total_earned" >= 0),
    "total_spent"      INT DEFAULT 0 CHECK ("total_spent" >= 0),
    "balance"          INT DEFAULT 0 CHECK ("balance" >= 0),
    "last_activity_at" TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_loyalty_user ON "LoyaltyAccount"("user_id");

CREATE TABLE IF NOT EXISTS "LoyaltyTransaction" (
    "id"                 SERIAL PRIMARY KEY,
    "loyalty_account_id" INT NOT NULL REFERENCES "LoyaltyAccount"("id") ON DELETE CASCADE,
    "order_id"           INT REFERENCES "Order"("id") ON DELETE SET NULL,
    "points"             INT NOT NULL,
    "type"               VARCHAR(20) NOT NULL
                         CHECK ("type" IN ('earn', 'redeem', 'expire', 'bonus')),
    "description"        TEXT,
    "created_at"         TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_loyalty_txn_account ON "LoyaltyTransaction"("loyalty_account_id");
CREATE INDEX IF NOT EXISTS idx_loyalty_txn_order ON "LoyaltyTransaction"("order_id");
