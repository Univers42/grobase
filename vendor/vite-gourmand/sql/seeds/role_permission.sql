-- ============================================
-- SEED: RolePermission mapping
-- ============================================
-- Roles: superadmin(1), admin(2), employee(3), utilisateur(4)
-- Strategy: superadmin gets ALL, admin gets all except superadmin-only,
-- employee gets operational subset, utilisateur gets client subset.
-- ============================================

-- superadmin (1) gets ALL permissions
INSERT INTO "RolePermission" ("role_id", "permission_id")
SELECT 1, "id" FROM "Permission"
ON CONFLICT DO NOTHING;

-- admin (2) gets all permissions (same as superadmin for business purposes)
INSERT INTO "RolePermission" ("role_id", "permission_id")
SELECT 2, "id" FROM "Permission"
ON CONFLICT DO NOTHING;

-- employee (3) gets operational permissions
INSERT INTO "RolePermission" ("role_id", "permission_id")
SELECT 3, "id" FROM "Permission" WHERE "name" IN (
    'create_menus', 'read_menus', 'update_menus', 'delete_menus',
    'manage_menus', 'manage_dishes',
    'read_orders', 'update_orders', 'manage_orders', 'view_all_orders', 'update_order',
    'read_reviews', 'update_reviews', 'moderate_reviews',
    'manage_hours', 'update_settings'
) ON CONFLICT DO NOTHING;

-- utilisateur (4) gets client permissions
INSERT INTO "RolePermission" ("role_id", "permission_id")
SELECT 4, "id" FROM "Permission" WHERE "name" IN (
    'read_menus', 'place_order', 'view_own_orders', 'write_review'
) ON CONFLICT DO NOTHING;
