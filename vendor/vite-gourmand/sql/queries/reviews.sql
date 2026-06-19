-- ============================================
-- REVIEW & MODERATION QUERIES
-- ============================================
-- Subject: "note entre 1 et 5, suivi d'un commentaire"
-- Subject: "valider les avis pour la page d'accueil"
-- ============================================

-- ============================================
-- PUBLIC: Approved reviews (homepage display)
-- ============================================

CREATE TEMP TABLE IF NOT EXISTS "review_status_constants" ("approved" TEXT);
TRUNCATE "review_status_constants";
INSERT INTO "review_status_constants" ("approved") VALUES ('approved');

SELECT
    "p"."note",
    "p"."description",
    "p"."created_at",
    "u"."first_name"
FROM "Publish" AS "p"
JOIN "User" AS "u" ON "p"."user_id" = "u"."id"
WHERE "p"."status" = (SELECT "approved" FROM "review_status_constants")
ORDER BY "p"."created_at" DESC
LIMIT 10;

-- Average rating across approved reviews
SELECT
    ROUND(AVG(CAST("note" AS INTEGER)), 2) AS "average_rating",
    COUNT(*) AS "total_reviews"
FROM "Publish"
WHERE "status" = (SELECT "approved" FROM "review_status_constants");

-- ============================================
-- EMPLOYEE: Moderation queue
-- ============================================

-- Pending reviews waiting for approval
SELECT
    "p"."id",
    "p"."note",
    "p"."description",
    "p"."created_at",
    "u"."first_name",
    "u"."last_name",
    "u"."email"
FROM "Publish" AS "p"
JOIN "User" AS "u" ON "p"."user_id" = "u"."id"
WHERE "p"."status" = 'pending'
ORDER BY "p"."created_at" ASC;

-- Approve a review
UPDATE "Publish"
SET
    "status" = (SELECT "approved" FROM "review_status_constants"),
    "moderated_by" = 4,  -- $1: employee user_id
    "moderated_at" = CURRENT_TIMESTAMP,
    "updated_at" = CURRENT_TIMESTAMP
WHERE "id" = 5;  -- $2: review_id

-- Reject a review
UPDATE "Publish"
SET
    "status" = 'rejected',
    "moderated_by" = 4,
    "moderated_at" = CURRENT_TIMESTAMP,
    "updated_at" = CURRENT_TIMESTAMP
WHERE "id" = 7;

-- ============================================
-- CLIENT: Submit a review
-- ============================================

-- Subject: review only after order completed
INSERT INTO "Publish" ("user_id", "order_id", "note", "description", "status")
SELECT
    7,     -- $1: user_id
    1,     -- $2: order_id
    '5',   -- $3: note (1–5)
    'Excellent service, merci !',  -- $4: description
    'pending'
WHERE EXISTS (
    SELECT 1 FROM "Order"
    WHERE "id" = 1
      AND "user_id" = 7
      AND "status" = 'completed'
)
RETURNING "id";

-- ============================================
-- STATISTICS
-- ============================================

-- Review count by status
SELECT "status", COUNT(*) AS "count"
FROM "Publish"
GROUP BY "status"
ORDER BY "count" DESC;

-- Rating distribution
SELECT "note", COUNT(*) AS "count"
FROM "Publish"
WHERE "status" = (SELECT "approved" FROM "review_status_constants")
GROUP BY "note"
ORDER BY "note" DESC;
