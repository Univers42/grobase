-- ============================================
-- SEED: Permissions (RBAC matrix)
-- ============================================

INSERT INTO "Permission" ("name", "resource", "action") VALUES
    ('create_users',    'users',     'create'),
    ('read_users',      'users',     'read'),
    ('update_users',    'users',     'update'),
    ('delete_users',    'users',     'delete'),
    ('create_menus',    'menus',     'create'),
    ('read_menus',      'menus',     'read'),
    ('update_menus',    'menus',     'update'),
    ('delete_menus',    'menus',     'delete'),
    ('read_orders',     'orders',    'read'),
    ('update_orders',   'orders',    'update'),
    ('read_reviews',    'reviews',   'read'),
    ('update_reviews',  'reviews',   'update'),
    ('read_analytics',  'analytics', 'read'),
    ('update_settings', 'settings',  'update'),
    ('manage_users',     'users',     'manage'),
    ('create_employee',  'users',     'create'),
    ('disable_employee', 'users',     'disable'),
    ('manage_menus',     'menus',     'manage'),
    ('manage_dishes',    'dishes',    'manage'),
    ('manage_orders',    'orders',    'manage'),
    ('view_all_orders',  'orders',    'read'),
    ('update_order',     'orders',    'update'),
    ('moderate_reviews', 'reviews',   'moderate'),
    ('view_analytics',   'analytics', 'read'),
    ('manage_hours',     'hours',     'manage'),
    ('place_order',      'orders',    'create'),
    ('view_own_orders',  'orders',    'read_own'),
    ('write_review',     'reviews',   'create'),
    ('manage_discounts', 'discounts', 'manage')
ON CONFLICT ("name") DO NOTHING;
