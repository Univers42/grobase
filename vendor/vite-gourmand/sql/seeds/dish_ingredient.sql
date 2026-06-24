INSERT INTO "DishIngredient" ("dish_id","ingredient_id","quantity") VALUES
    (1,1,0.150),(1,5,0.050),               -- Foie Gras: foie gras + farine
    (2,3,0.200),(2,10,0.100),              -- Velouté: champignons + crème
    (3,8,0.200),                           -- Tartare: saumon
    (4,2,0.250),(4,3,0.100),(4,5,0.050),(4,6,0.030), -- Wellington
    (5,3,0.150),(5,9,0.100),(5,6,0.020),   -- Risotto
    (6,7,0.400),(6,6,0.020),               -- Homard
    (7,2,0.350),                           -- Côte de bœuf
    (8,4,2.000),(8,6,0.030),               -- Œufs Bénédicte: eggs + butter
    (9,4,3.000),(9,5,0.080),(9,6,0.060),   -- Paris-Brest
    (10,4,3.000),(10,10,0.150),            -- Crème Brûlée
    (13,2,0.200),                          -- Magret (uses beef slot for now)
    (14,8,0.250),(14,6,0.030),             -- Cabillaud: saumon slot + butter
    (15,13,0.200),(15,14,0.150),           -- Ratatouille: tomates + courgettes
    (16,15,0.300),(16,6,0.050),(16,5,0.080), -- Tarte Tatin
    (17,11,0.150),(17,4,2.000),(17,6,0.040), -- Fondant chocolat
    (18,10,0.200),(18,12,0.100),           -- Panna Cotta
    (19,13,0.300),                         -- Gazpacho: tomates
    (20,14,0.200),(20,13,0.200)            -- Tian: courgettes + tomates
ON CONFLICT DO NOTHING;
