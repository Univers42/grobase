-- ============================================
-- SEED: UserPromotion (targeted offers)
-- ============================================
-- Assign the VIP loyalty promotion (id=6) to loyal customers
-- Users: 8=alice, 9=bob, 19=nicolas (frequent clients)
-- ============================================

INSERT INTO "UserPromotion" ("user_id", "promotion_id", "is_seen", "is_used", "used_at") VALUES
    (8,  6, TRUE,  FALSE, NULL),                          -- Alice: seen but not used
    (9,  6, FALSE, FALSE, NULL),                          -- Bob: not seen yet
    (19, 6, TRUE,  TRUE,  '2026-01-20 14:30:00'),         -- Nicolas: already used
    (8,  1, TRUE,  TRUE,  '2026-01-05 10:00:00'),         -- Alice used BIENVENUE10
    (12, 1, FALSE, FALSE, NULL)                            -- Emma: welcome offer assigned
ON CONFLICT DO NOTHING;
