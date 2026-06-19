INSERT INTO "Ingredient" ("name","unit","current_stock","min_stock_level","cost_per_unit") VALUES
    ('Foie Gras',       'kg',     5.0,  1.0, 120.00),
    ('Filet de Bœuf',   'kg',    20.0,  5.0,  45.00),
    ('Champignons',     'kg',    15.0,  3.0,   8.00),
    ('Œufs',            'pièces',200,  50,     0.30),
    ('Farine',          'kg',    50.0, 10.0,   1.50),
    ('Beurre',          'kg',    10.0,  2.0,  12.00),
    ('Homard',          'kg',     8.0,  2.0,  80.00),
    ('Saumon',          'kg',    12.0,  3.0,  25.00),
    ('Riz Arborio',     'kg',    20.0,  5.0,   4.00),
    ('Crème Fraîche',   'litres',15.0,  3.0,   5.00),
    ('Chocolat noir',   'kg',     8.0,  2.0,  18.00),
    ('Framboises',      'kg',     5.0,  1.0,  22.00),
    ('Tomates',         'kg',    25.0,  5.0,   3.00),
    ('Courgettes',      'kg',    15.0,  3.0,   2.50),
    ('Pommes',          'kg',    20.0,  5.0,   2.00)
ON CONFLICT ("name") DO NOTHING;
