-- ============================================
-- SEED: DishAllergen (explicit junction)
-- + _DishAllergens (Prisma implicit M:N)
-- ============================================
-- Both tables are populated to support both query patterns.
-- Allergen IDs: 1=Gluten, 2=Crustacés, 3=Œufs, 4=Poisson,
--   5=Arachides, 6=Soja, 7=Lait, 8=Fruits à coque,
--   9=Céleri, 10=Moutarde, 11=Sésame, 12=Sulfites,
--   13=Lupin, 14=Mollusques
-- ============================================

-- Explicit junction (for direct SQL queries)
INSERT INTO "DishAllergen" ("dish_id", "allergen_id") VALUES
    (1, 1), (1, 3),           -- Foie Gras: Gluten, Œufs
    (2, 7), (2, 9),           -- Velouté: Lait, Céleri
    (3, 4), (3, 10),          -- Tartare Saumon: Poisson, Moutarde
    (4, 1), (4, 3), (4, 7),   -- Wellington: Gluten, Œufs, Lait
    (5, 7), (5, 9),           -- Risotto: Lait, Céleri
    (6, 2),                    -- Homard: Crustacés
    (8, 1), (8, 3), (8, 7),   -- Œufs Bénédicte: Gluten, Œufs, Lait
    (9, 1), (9, 3), (9, 7), (9, 8), -- Paris-Brest: Gluten, Œufs, Lait, Fruits à coque
    (10, 3), (10, 7),         -- Crème Brûlée: Œufs, Lait
    (11, 1), (11, 3), (11, 7), -- Salade César: Gluten, Œufs, Lait
    (16, 1), (16, 7),         -- Tarte Tatin: Gluten, Lait
    (17, 3), (17, 7),         -- Fondant Chocolat: Œufs, Lait
    (18, 7)                    -- Panna Cotta: Lait
ON CONFLICT DO NOTHING;

-- Prisma implicit M:N junction (A=allergen_id, B=dish_id)
INSERT INTO "_DishAllergens" ("A","B") VALUES
    (1,1),(3,1),               -- Foie Gras: Gluten, Œufs
    (7,2),(9,2),               -- Velouté: Lait, Céleri
    (4,3),(10,3),              -- Tartare Saumon: Poisson, Moutarde
    (1,4),(3,4),(7,4),         -- Wellington: Gluten, Œufs, Lait
    (7,5),(9,5),               -- Risotto: Lait, Céleri
    (2,6),                     -- Homard: Crustacés
    (1,8),(3,8),(7,8),         -- Œufs Bénédicte: Gluten, Œufs, Lait
    (1,9),(3,9),(7,9),(8,9),   -- Paris-Brest: Gluten, Œufs, Lait, Fruits à coque
    (3,10),(7,10),             -- Crème Brûlée: Œufs, Lait
    (1,11),(3,11),(7,11),      -- Salade César: Gluten, Œufs, Lait
    (1,16),(7,16),             -- Tarte Tatin: Gluten, Lait
    (3,17),(7,17),             -- Fondant Chocolat: Œufs, Lait
    (7,18)                     -- Panna Cotta: Lait
ON CONFLICT DO NOTHING;
