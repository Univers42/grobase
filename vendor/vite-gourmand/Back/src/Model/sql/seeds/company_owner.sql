-- ============================================
-- SEED: CompanyOwner (M:N junction)
-- ============================================
-- Links company owners (José & Julie) to the company
-- Users: 2=José (admin), 3=Julie (admin)
-- ============================================

INSERT INTO "CompanyOwner" ("company_id", "user_id", "role", "is_primary") VALUES
    (1, 2, 'owner', TRUE),      -- José - primary owner
    (1, 3, 'owner', FALSE)      -- Julie - co-owner
ON CONFLICT DO NOTHING;
