-- ============================================
-- SCHEMA: GDPR & Consent
-- ============================================

CREATE TABLE IF NOT EXISTS "UserConsent" (
    "id"           SERIAL PRIMARY KEY,
    "user_id"      INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "consent_type" VARCHAR(50) NOT NULL,
    "is_granted"   BOOLEAN NOT NULL,
    "granted_at"   TIMESTAMPTZ,
    "revoked_at"   TIMESTAMPTZ,
    "ip_address"   VARCHAR(45)
);

CREATE INDEX IF NOT EXISTS idx_consent_user ON "UserConsent"("user_id");

-- --------------------------------------------
-- Data Deletion Requests (Right to Erasure)
-- --------------------------------------------
CREATE TABLE IF NOT EXISTS "DataDeletionRequest" (
    "id"           SERIAL PRIMARY KEY,
    "user_id"      INT REFERENCES "User"("id") ON DELETE SET NULL,
    "reason"       TEXT,
    "status"       VARCHAR(20) DEFAULT 'pending',
    "requested_at" TIMESTAMPTZ DEFAULT NOW(),
    "processed_at" TIMESTAMPTZ,
    "processed_by" INT REFERENCES "User"("id")
);

COMMENT ON TABLE "DataDeletionRequest" IS 'GDPR deletion requests. Admin must process within 72 hours.';
