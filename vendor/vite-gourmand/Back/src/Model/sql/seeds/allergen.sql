-- 14 major EU allergens (Regulation 1169/2011)
INSERT INTO "Allergen" ("name") VALUES
    ('Gluten'),('Crustacés'),('Œufs'),('Poisson'),
    ('Arachides'),('Soja'),('Lait'),('Fruits à coque'),
    ('Céleri'),('Moutarde'),('Sésame'),('Sulfites'),
    ('Lupin'),('Mollusques')
ON CONFLICT ("name") DO NOTHING;
