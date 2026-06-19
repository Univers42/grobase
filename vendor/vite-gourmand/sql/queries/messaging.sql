-- ============================================
-- MESSAGING & NOTIFICATION QUERIES
-- ============================================

-- Send a message
INSERT INTO "Message" ("sender_id", "recipient_id", "subject", "body", "priority")
VALUES (2, 4, 'Réunion lundi', 'Peux-tu être là à 9h ?', 'normal')
RETURNING "id";

-- Inbox (unread first)
SELECT "id", "subject", "body", "priority", "is_read", "sent_at",
       (SELECT "first_name" FROM "User" WHERE "id" = "m"."sender_id") AS "from"
FROM "Message" AS "m"
WHERE "recipient_id" = 4
ORDER BY "is_read" ASC, "sent_at" DESC;

-- Mark as read
UPDATE "Message"
SET "is_read" = TRUE, "read_at" = CURRENT_TIMESTAMP
WHERE "id" = 1 AND "recipient_id" = 4;

-- Unread notification count
SELECT COUNT(*) AS "unread_count"
FROM "Notification"
WHERE "user_id" = 7 AND NOT "is_read";

-- Get notifications
SELECT "type", "title", "body", "link_url", "created_at"
FROM "Notification"
WHERE "user_id" = 7
ORDER BY "created_at" DESC
LIMIT 20;

-- Mark notification as read
UPDATE "Notification"
SET "is_read" = TRUE, "read_at" = CURRENT_TIMESTAMP
WHERE "id" = 2 AND "user_id" = 7;
