-- ============================================
-- CONTACT FORM QUERIES
-- ============================================

-- Submit a contact message
INSERT INTO "ContactMessage" ("title", "description", "email")
VALUES (
    'Demande d''information',
    'Je souhaite en savoir plus sur vos menus de Noël.',
    'visiteur@email.fr'
)
RETURNING "id", "created_at";

-- Admin: view all contact messages (newest first)
SELECT "id", "title", "email", "created_at"
FROM "ContactMessage"
ORDER BY "created_at" DESC;

-- Admin: view a specific message
SELECT "id", "title", "description", "email", "created_at"
FROM "ContactMessage"
WHERE "id" = 1;

-- Admin: delete old messages (older than 6 months)
DELETE FROM "ContactMessage"
WHERE "created_at" < CURRENT_TIMESTAMP - INTERVAL '180 days';
