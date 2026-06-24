-- ============================================
-- SEED: Newsletter Subscribers
-- ============================================
-- Some registered clients opted in, plus a few anonymous visitors.
-- Token format: 'nl_<email-hash>_<random>' for unsubscribe links.
-- ============================================

-- Update existing users with newsletter_consent
UPDATE "User" SET "newsletter_consent" = TRUE, "newsletter_consent_date" = NOW()
WHERE "email" IN (
    'alice@example.fr',
    'bob@example.fr',
    'claire@example.fr',
    'emma@example.fr',
    'karim@example.fr',
    'laura@example.fr'
);

-- Registered user subscribers (linked to user_id)
INSERT INTO "NewsletterSubscriber" ("email", "user_id", "first_name", "is_active", "token", "confirmed_at")
VALUES
    ('alice@example.fr',    8,  'Alice',    TRUE, 'nl_alice_a1b2c3d4e5', NOW()),
    ('bob@example.fr',      9,  'Bob',      TRUE, 'nl_bob_f6g7h8i9j0',   NOW()),
    ('claire@example.fr',   10, 'Claire',   TRUE, 'nl_claire_k1l2m3n4',  NOW()),
    ('emma@example.fr',     12, 'Emma',     TRUE, 'nl_emma_o5p6q7r8s9',  NOW()),
    ('karim@example.fr',    17, 'Karim',    TRUE, 'nl_karim_t0u1v2w3x4', NOW()),
    ('laura@example.fr',    18, 'Laura',    TRUE, 'nl_laura_y5z6a7b8c9', NOW())
ON CONFLICT ("email") DO NOTHING;

-- Anonymous visitor subscribers (no user_id)
INSERT INTO "NewsletterSubscriber" ("email", "user_id", "first_name", "is_active", "token", "confirmed_at")
VALUES
    ('marie.visiteur@gmail.com',  NULL, 'Marie',   TRUE, 'nl_marie_d0e1f2g3h4',   NOW()),
    ('thomas.curieux@outlook.fr', NULL, 'Thomas',  TRUE, 'nl_thomas_i5j6k7l8m9',  NOW()),
    ('sophie.gourmande@free.fr',  NULL, 'Sophie',  TRUE, 'nl_sophie_n0o1p2q3r4',  NOW()),
    ('unsubbed@example.com',      NULL, 'Ex-Sub',  FALSE, 'nl_unsub_s5t6u7v8w9',  NULL)
ON CONFLICT ("email") DO NOTHING;

-- Mark the unsubbed one
UPDATE "NewsletterSubscriber" SET "unsubscribed_at" = NOW() - INTERVAL '30 days'
WHERE "email" = 'unsubbed@example.com';
