-- ============================================
-- EMPLOYEE MANAGEMENT QUERIES
-- ============================================

-- Submit time-off request
INSERT INTO "TimeOffRequest" ("user_id", "start_date", "end_date", "type", "reason")
VALUES (4, '2026-07-01', '2026-07-14', 'vacation', 'Vacances d''été')
RETURNING "id";

-- Admin: view pending requests
SELECT
    "t"."id", "t"."start_date", "t"."end_date", "t"."type", "t"."reason",
    "u"."first_name", "u"."last_name"
FROM "TimeOffRequest" AS "t"
JOIN "User" AS "u" ON "t"."user_id" = "u"."id"
WHERE "t"."status" = 'pending'
ORDER BY "t"."requested_at" ASC;

-- Admin: approve request
UPDATE "TimeOffRequest"
SET "status" = 'approved',
    "decided_by" = 2,
    "decided_at" = CURRENT_TIMESTAMP
WHERE "id" = 3;

-- Admin: reject request
UPDATE "TimeOffRequest"
SET "status" = 'rejected',
    "decided_by" = 2,
    "decided_at" = CURRENT_TIMESTAMP
WHERE "id" = 3;

-- Employee availability check (is someone off on a given date?)
SELECT "u"."first_name", "u"."last_name", "t"."start_date", "t"."end_date"
FROM "TimeOffRequest" AS "t"
JOIN "User" AS "u" ON "t"."user_id" = "u"."id"
WHERE "t"."status" = 'approved'
  AND '2026-08-05' BETWEEN "t"."start_date" AND "t"."end_date";
