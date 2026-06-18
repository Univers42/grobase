INSERT INTO "Discount" ("code", "description", "type", "value", "min_order_amount", "max_uses", "current_uses", "valid_from", "valid_until", "is_active", "created_by") VALUES
    ('BIENVENUE10', 'Réduction bienvenue 10%', 'percentage', 10.00, 100.00, NULL, 15, '2026-01-01', '2026-12-31', TRUE, 2),
    ('ETE2026', 'Promo été 2026', 'percentage', 15.00, 200.00, 50, 3, '2026-06-01', '2026-08-31', TRUE, 2),
    ('FIDELE50', 'Remise fidélité 50€', 'fixed_amount', 50.00, 500.00, 100, 12, '2026-01-01', '2026-12-31', TRUE, 2),
    ('EXPIRE2025', 'Code expiré test', 'percentage', 20.00, NULL, NULL, 0, '2025-01-01', '2025-12-31', FALSE, 2),
    ('NOEL2026', 'Réduction Noël', 'percentage', 20.00, 300.00, 30, 0, '2026-12-01', '2026-12-25', TRUE, 2);
