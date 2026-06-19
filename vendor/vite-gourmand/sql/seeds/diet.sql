INSERT INTO "Diet" ("name", "description") VALUES
    ('Classique',   'Menu traditionnel sans restriction'),
    ('Végétarien',  'Sans viande ni poisson'),
    ('Végan',       'Sans produit d''origine animale'),
    ('Sans Gluten', 'Adapté aux intolérants au gluten'),
    ('Halal',       'Conforme aux prescriptions halal'),
    ('Casher',      'Conforme aux prescriptions casher')
ON CONFLICT ("name") DO NOTHING;
