INSERT INTO "Theme" ("name", "description") VALUES
    ('Mariage',        'Réceptions de mariage'),
    ('Anniversaire',   'Fêtes d''anniversaire'),
    ('Baptême',        'Cérémonies de baptême'),
    ('Entreprise',     'Événements professionnels'),
    ('Cocktail',       'Réceptions cocktail'),
    ('Gastronomique',  'Expérience culinaire haut de gamme'),
    ('Barbecue',       'Événements en extérieur'),
    ('Brunch',         'Petit-déjeuner tardif'),
    ('Noël',           'Repas de fêtes de fin d''année'),
    ('Pâques',         'Repas de Pâques')
ON CONFLICT ("name") DO NOTHING;
