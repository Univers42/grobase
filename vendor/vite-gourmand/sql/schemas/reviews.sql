-- ============================================
-- REVIEWS & MODERATION SCHEMA
-- ============================================
-- Covers: Publish, ReviewImage
-- Subject: "note entre 1 et 5, suivi d'un commentaire"
-- Subject: "valider les avis pour qu'ils soient visibles"
-- ============================================

CREATE TABLE IF NOT EXISTS "Publish" (
    "id"           SERIAL PRIMARY KEY,
    "user_id"      INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "order_id"     INT REFERENCES "Order"("id") ON DELETE SET NULL,
    "note"         SMALLINT NOT NULL CHECK ("note" BETWEEN 1 AND 5),
    "description"  TEXT NOT NULL,
    "status"       VARCHAR(20) DEFAULT 'pending' CHECK ("status" IN ('pending', 'approved', 'rejected')),
    "moderated_by" INT REFERENCES "User"("id"),
    "moderated_at" TIMESTAMPTZ,
    "created_at"   TIMESTAMPTZ DEFAULT NOW(),
    "updated_at"   TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE  "Publish"            IS 'Customer reviews — moderated before homepage display.';
COMMENT ON COLUMN "Publish"."note"     IS 'Subject: rating 1–5 stars.';
COMMENT ON COLUMN "Publish"."status"   IS 'Subject: employee approves/rejects for visibility.';

CREATE INDEX IF NOT EXISTS idx_publish_status ON "Publish"("status");
CREATE INDEX IF NOT EXISTS idx_publish_user ON "Publish"("user_id");

-- Review images (bonus)
CREATE TABLE IF NOT EXISTS "ReviewImage" (
    "id"          SERIAL PRIMARY KEY,
    "review_id"   INTEGER      NOT NULL REFERENCES "Publish"("id") ON DELETE CASCADE,
    "image_url"   VARCHAR(500) NOT NULL,
    "uploaded_at" TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);
