-- ============================================
-- SCHEMA: Promotions & Publicity
-- ============================================
-- Unified promotion system that merges:
--   • Public-facing banners / publicity (visible to everyone)
--   • Discount codes (linked to existing Discount table)
--   • User-targeted promotions (personal offers)
--
-- Depends on: auth.sql (User), loyalty.sql (Discount)
-- ============================================

-- Promotion: the main entity for banners, campaigns, publicity
CREATE TABLE IF NOT EXISTS "Promotion" (
    "id"               SERIAL PRIMARY KEY,
    "title"            VARCHAR(150) NOT NULL,
    "description"      TEXT,
    "short_text"       VARCHAR(255),                                    -- banner one-liner
    "type"             VARCHAR(30) NOT NULL DEFAULT 'banner'
                       CHECK ("type" IN ('banner', 'popup', 'discount', 'loyalty', 'seasonal', 'flash_sale')),
    "image_url"        TEXT,
    "link_url"         TEXT,                                            -- CTA link (menu page, contact, etc.)
    "link_label"       VARCHAR(80),                                     -- CTA button text
    "badge_text"       VARCHAR(40),                                     -- e.g. "-20%", "NOUVEAU", "🔥"
    "bg_color"         VARCHAR(20) DEFAULT '#722F37',                   -- banner background
    "text_color"       VARCHAR(20) DEFAULT '#FFFFFF',                   -- banner text
    "discount_id"      INT REFERENCES "Discount"("id") ON DELETE SET NULL,  -- optional linked discount
    "priority"         INT DEFAULT 0,                                   -- higher = shown first
    "is_active"        BOOLEAN DEFAULT TRUE,
    "is_public"        BOOLEAN DEFAULT TRUE,                            -- visible to non-logged users
    "start_date"       TIMESTAMP NOT NULL DEFAULT NOW(),
    "end_date"         TIMESTAMP,                                       -- NULL = never expires
    "created_by"       INT REFERENCES "User"("id") ON DELETE SET NULL,
    "created_at"       TIMESTAMP DEFAULT NOW(),
    "updated_at"       TIMESTAMP DEFAULT NOW()
);

-- User-targeted promotions (M:N join table)
-- When a promotion targets specific users (personal discount, loyalty reward)
CREATE TABLE IF NOT EXISTS "UserPromotion" (
    "id"               SERIAL PRIMARY KEY,
    "user_id"          INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "promotion_id"     INT NOT NULL REFERENCES "Promotion"("id") ON DELETE CASCADE,
    "is_seen"          BOOLEAN DEFAULT FALSE,
    "is_used"          BOOLEAN DEFAULT FALSE,
    "used_at"          TIMESTAMP,
    "assigned_at"      TIMESTAMP DEFAULT NOW(),
    UNIQUE ("user_id", "promotion_id")
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS "idx_promotion_active_dates"
    ON "Promotion" ("is_active", "start_date", "end_date")
    WHERE "is_active" = TRUE;

CREATE INDEX IF NOT EXISTS "idx_promotion_public"
    ON "Promotion" ("is_public", "is_active", "priority" DESC)
    WHERE "is_public" = TRUE AND "is_active" = TRUE;

CREATE INDEX IF NOT EXISTS "idx_user_promotion_user"
    ON "UserPromotion" ("user_id", "is_used");

CREATE INDEX IF NOT EXISTS "idx_user_promotion_promo"
    ON "UserPromotion" ("promotion_id");
