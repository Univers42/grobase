-- ============================================
-- LOYALTY & PROMOTIONS QUERIES
-- ============================================

-- Get loyalty balance for a user
SELECT "balance", "total_earned", "total_spent", "last_activity_at"
FROM "LoyaltyAccount"
WHERE "user_id" = 7;

-- Transaction history
SELECT "points", "type", "description", "created_at"
FROM "LoyaltyTransaction"
WHERE "loyalty_account_id" = (SELECT "id" FROM "LoyaltyAccount" WHERE "user_id" = 7)
ORDER BY "created_at" DESC;

-- Earn points after delivery
INSERT INTO "LoyaltyTransaction" ("loyalty_account_id", "order_id", "points", "type", "description")
VALUES (
    (SELECT "id" FROM "LoyaltyAccount" WHERE "user_id" = 7),
    5, 1470, 'earn', 'Commande ORD-2026-00005 livrée'
);

UPDATE "LoyaltyAccount"
SET "total_earned" = "total_earned" + 1470,
    "balance" = "balance" + 1470,
    "last_activity_at" = CURRENT_TIMESTAMP
WHERE "user_id" = 7;

-- Validate a promo code
SELECT "id", "code", "type", "value", "min_order_amount"
FROM "Discount"
WHERE "code" = 'BIENVENUE10'
  AND "is_active"
  AND ("valid_from" IS NULL OR "valid_from" <= CURRENT_DATE)
  AND ("valid_until" IS NULL OR "valid_until" >= CURRENT_DATE)
  AND ("max_uses" IS NULL OR "current_uses" < "max_uses");
