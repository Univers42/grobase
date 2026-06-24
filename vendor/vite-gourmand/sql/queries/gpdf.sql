-- ============================================
-- GDPR COMPLIANCE QUERIES
-- ============================================
-- Right to Access, Right to Erasure,
-- Consent Management, Data Export
-- ============================================

-- ============================================
-- RIGHT TO ACCESS: Data export
-- ============================================

-- Export user profile
SELECT "id", "email", "first_name", "last_name",
       "phone_number", "city", "country", "postal_code",
       "gdpr_consent", "marketing_consent", "created_at"
FROM "User"
WHERE "id" = 7  -- $1: user_id
  AND NOT "is_deleted";

-- Export user orders
SELECT "order_number", "order_date", "delivery_date",
       "total_price", "status", "person_number"
FROM "Order"
WHERE "user_id" = 7
ORDER BY "order_date" DESC;

-- Export user reviews
SELECT "note", "description", "status", "created_at"
FROM "Publish"
WHERE "user_id" = 7;

-- Export user consents
SELECT "consent_type", "is_granted", "granted_at", "revoked_at"
FROM "UserConsent"
WHERE "user_id" = 7;

-- ============================================
-- RIGHT TO ERASURE: Soft delete + anonymize
-- ============================================

-- Step 1: Create deletion request
INSERT INTO "DataDeletionRequest" ("user_id", "reason", "status")
VALUES (7, 'Demande de suppression de compte', 'pending')
RETURNING "id";

-- Step 2: Admin approves → soft delete
BEGIN;

UPDATE "DataDeletionRequest"
SET "status" = 'approved', "processed_at" = CURRENT_TIMESTAMP, "processed_by" = 2
WHERE "id" = 1;

UPDATE "User"
SET "is_deleted" = TRUE,
    "deleted_at" = CURRENT_TIMESTAMP,
    "email" = 'deleted_' || "id" || '@anonymized.local',
    "first_name" = 'Utilisateur',
    "last_name" = 'Supprimé',
    "phone_number" = NULL,
    "city" = NULL,
    "postal_code" = NULL,
    "is_active" = FALSE,
    "updated_at" = CURRENT_TIMESTAMP
WHERE "id" = 7;

-- Invalidate all sessions
UPDATE "UserSession"
SET "is_active" = FALSE
WHERE "user_id" = 7;

UPDATE "DataDeletionRequest"
SET "status" = 'completed'
WHERE "id" = 1;

COMMIT;

-- ============================================
-- CONSENT MANAGEMENT
-- ============================================

-- Grant marketing consent
INSERT INTO "UserConsent" ("user_id", "consent_type", "is_granted", "granted_at", "ip_address")
VALUES (7, 'marketing', TRUE, CURRENT_TIMESTAMP, '82.120.45.12');

-- Revoke marketing consent
UPDATE "UserConsent"
SET "is_granted" = FALSE, "revoked_at" = CURRENT_TIMESTAMP
WHERE "user_id" = 7 AND "consent_type" = 'marketing';

-- Check consent status for a user
SELECT "consent_type", "is_granted", "granted_at", "revoked_at"
FROM "UserConsent"
WHERE "user_id" = 7
ORDER BY "consent_type" ASC;
