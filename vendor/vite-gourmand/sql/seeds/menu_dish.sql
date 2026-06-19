-- _MenuDishes: A=dish_id, B=menu_id
INSERT INTO "_MenuDishes" ("A","B") VALUES
    (1,1),(12,1),(4,1),(13,1),(9,1),(10,1),   -- Menu 1: Prestige Mariage
    (2,2),(19,2),(5,2),(15,2),(16,2),(18,2),   -- Menu 2: Végétarien
    (1,3),(3,3),(11,3),(12,3),                 -- Menu 3: Cocktail
    (8,4),(11,4),(9,4),(17,4),                 -- Menu 4: Brunch
    (1,5),(3,5),(6,5),(13,5),(9,5),(10,5),     -- Menu 5: Gastronomique
    (11,6),(7,6),(20,6),(16,6),                -- Menu 6: Barbecue
    (19,7),(15,7),(20,7),(18,7),               -- Menu 7: Végan
    (1,8),(2,8),(13,8),(14,8),(9,8),(17,8),    -- Menu 8: Noël
    (12,9),(2,9),(14,9),(5,9),(10,9),(16,9),   -- Menu 9: Pâques
    (4,10),(10,10)                             -- Menu 10: Brouillon
ON CONFLICT DO NOTHING;
