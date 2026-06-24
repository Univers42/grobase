-- ============================================
-- SCHEMA: Contact form
-- ============================================

CREATE TABLE IF NOT EXISTS "ContactMessage" (
    "id"          SERIAL PRIMARY KEY,
    "title"       VARCHAR(255) NOT NULL,
    "description" TEXT NOT NULL,
    "email"       VARCHAR(255) NOT NULL,
    "created_at"  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_contact_date ON "ContactMessage"("created_at" DESC);
