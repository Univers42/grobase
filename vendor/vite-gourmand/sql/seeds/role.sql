-- ============================================
-- SEED: Roles (4 subject roles)
-- ============================================

-- Roles: superadmin(1), admin(2), employee(3), utilisateur(4)
INSERT INTO "Role" ("name", "description") VALUES
    ('superadmin',  'Full system access — developer only'),
    ('admin',       'Business admin — José, Julie'),
    ('employee',    'Staff — menu/order/review management'),
    ('utilisateur', 'Client — browse, order, review')
ON CONFLICT ("name") DO NOTHING;
