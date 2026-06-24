-- ============================================
-- SCHEMA: Newsletter Subscribers
-- ============================================
-- Allows both registered users and anonymous visitors
-- to subscribe to promotional newsletters.
-- Linked to the Promotion system for automated sends.
--
-- Depends on: auth.sql (User — optional FK)
-- ============================================

-- Add newsletter_consent column to User table if not exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'User' AND column_name = 'newsletter_consent'
    ) THEN
        ALTER TABLE "User" ADD COLUMN "newsletter_consent" BOOLEAN DEFAULT FALSE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'User' AND column_name = 'newsletter_consent_date'
    ) THEN
        ALTER TABLE "User" ADD COLUMN "newsletter_consent_date" TIMESTAMPTZ;
    END IF;
END
$$;

-- Newsletter subscribers table (for anonymous + registered users)
CREATE TABLE IF NOT EXISTS "NewsletterSubscriber" (
    "id"               SERIAL PRIMARY KEY,
    "email"            VARCHAR(255) NOT NULL,
    "user_id"          INT REFERENCES "User"("id") ON DELETE SET NULL,
    "first_name"       VARCHAR(100),
    "is_active"        BOOLEAN DEFAULT TRUE,
    "token"            VARCHAR(255) UNIQUE NOT NULL,
    "confirmed_at"     TIMESTAMPTZ,
    "unsubscribed_at"  TIMESTAMPTZ,
    "created_at"       TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE ("email")
);

CREATE INDEX IF NOT EXISTS idx_newsletter_email ON "NewsletterSubscriber"("email");
CREATE INDEX IF NOT EXISTS idx_newsletter_active ON "NewsletterSubscriber"("is_active") WHERE "is_active" = TRUE;
CREATE INDEX IF NOT EXISTS idx_newsletter_user ON "NewsletterSubscriber"("user_id");

-- Newsletter send log (tracks which promotions were sent)
CREATE TABLE IF NOT EXISTS "NewsletterSendLog" (
    "id"               SERIAL PRIMARY KEY,
    "promotion_id"     INT NOT NULL REFERENCES "Promotion"("id") ON DELETE CASCADE,
    "recipients_count" INT NOT NULL DEFAULT 0,
    "sent_at"          TIMESTAMPTZ DEFAULT NOW(),
    "sent_by"          INT REFERENCES "User"("id") ON DELETE SET NULL,
    "status"           VARCHAR(20) DEFAULT 'sent' CHECK ("status" IN ('sent', 'failed', 'partial'))
);

CREATE INDEX IF NOT EXISTS idx_newsletter_log_promo ON "NewsletterSendLog"("promotion_id");

COMMENT ON TABLE "NewsletterSubscriber" IS 'Newsletter subscribers — both anonymous visitors and registered users.';
COMMENT ON TABLE "NewsletterSendLog" IS 'Log of newsletters sent for each promotion.';
COMMENT ON COLUMN "NewsletterSubscriber"."token" IS 'Unique token for email confirmation and unsubscribe links.';
