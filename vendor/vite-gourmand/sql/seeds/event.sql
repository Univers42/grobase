-- ============================================
-- SEED: Event (Catering events realized)
-- ============================================
-- Realistic portfolio of events for Vite & Gourmand
-- Since 2001 (25+ years), they've done 2000+ events
-- Here we seed representative samples across the years
-- ============================================

INSERT INTO "Event" ("company_id", "name", "description", "event_type", "guest_count", "event_date", "location", "is_public") VALUES
    -- 2025-2026 Recent Events
    (1, 'Mariage Dubois-Martin', 'Mariage élégant au Château de la Rivière', 'wedding', 120, '2026-02-14', 'Château de la Rivière, Saint-Michel-de-Fronsac', TRUE),
    (1, 'Gala Entreprise BNP Paribas', 'Soirée annuelle des collaborateurs', 'corporate', 200, '2026-01-25', 'Palais de la Bourse, Bordeaux', TRUE),
    (1, 'Anniversaire 50 ans M. Lefebvre', 'Fête surprise en famille', 'birthday', 45, '2026-01-18', 'Domicile privé, Mérignac', FALSE),
    (1, 'Séminaire Capgemini', 'Cocktail déjeunatoire et buffet', 'corporate', 80, '2026-01-10', 'Darwin Ecosystème, Bordeaux', TRUE),
    (1, 'Mariage Rodriguez-Garcia', 'Cérémonie franco-espagnole', 'wedding', 150, '2025-12-20', 'Château Smith Haut Lafitte, Martillac', TRUE),
    (1, 'Réveillon Nouvel An 2026', 'Soirée privée exclusive', 'party', 60, '2025-12-31', 'Villa privée, Cap Ferret', FALSE),
    (1, 'Baptême Petit Louis', 'Réception familiale après baptême', 'baptism', 35, '2025-11-15', 'Salle des fêtes, Pessac', TRUE),
    (1, 'Cocktail Cabinet Avocats Dumas', 'Inauguration nouveaux locaux', 'corporate', 100, '2025-10-20', 'Centre-ville Bordeaux', TRUE),
    (1, 'Mariage Fontaine-Berger', 'Mariage champêtre dans les vignes', 'wedding', 90, '2025-09-12', 'Château Margaux', TRUE),
    (1, 'Soirée Anniversaire Entreprise 20 ans', 'Fête des 20 ans de TechStart', 'corporate', 180, '2025-09-05', 'Hangar 14, Bordeaux', TRUE),

    -- 2024 Events
    (1, 'Mariage Laurent-Petit', 'Grand mariage traditionnel', 'wedding', 200, '2024-08-24', 'Château Pape Clément, Pessac', TRUE),
    (1, 'Séminaire Thales', 'Buffet déjeunatoire 3 jours', 'corporate', 150, '2024-06-10', 'Cité du Vin, Bordeaux', TRUE),
    (1, 'Communion Solennelle Marie', 'Déjeuner familial', 'communion', 50, '2024-05-19', 'Restaurant privé, Libourne', TRUE),
    (1, 'Mariage Moreau-Durand', 'Mariage intime au bord de l''eau', 'wedding', 65, '2024-07-06', 'Bassin d''Arcachon', TRUE),
    (1, 'Gala Association Caritative', 'Dîner de levée de fonds', 'charity', 120, '2024-04-15', 'Grand Théâtre, Bordeaux', TRUE),

    -- 2023 Events
    (1, 'Mariage Bernard-Simon', 'Mariage bohème', 'wedding', 110, '2023-09-09', 'Domaine de Valmont, Langon', TRUE),
    (1, 'Cocktail Lancement Produit', 'Présentation nouveau vin', 'corporate', 75, '2023-11-20', 'Château Lynch-Bages, Pauillac', TRUE),
    (1, 'Fête des 80 ans Mamie Rose', 'Grande fête familiale', 'birthday', 80, '2023-08-05', 'Domicile privé, Talence', TRUE),

    -- 2022 Events
    (1, 'Mariage Dupont-Lefevre', 'Mariage classique élégant', 'wedding', 130, '2022-06-18', 'Château de Rauzan', TRUE),
    (1, 'Repas de Noël Entreprise Aquitaine', 'Dîner de fin d''année', 'corporate', 95, '2022-12-16', 'Hôtel de Sèze, Bordeaux', TRUE),

    -- Historical Events (older, for stats)
    (1, 'Premier Grand Mariage', 'Notre premier mariage de plus de 100 personnes', 'wedding', 100, '2002-07-20', 'Château Ausone, Saint-Émilion', TRUE),
    (1, 'Inauguration Cave Coopérative', 'Événement fondateur local', 'corporate', 200, '2003-05-10', 'Cave de Rauzan', TRUE),
    (1, 'Mariage des 1000 premiers', 'Notre 1000ème événement !', 'wedding', 150, '2012-09-15', 'Château Mouton Rothschild', TRUE),
    (1, 'Fête des 10 ans Vite & Gourmand', 'Célébration décennale', 'party', 100, '2011-03-15', 'Nos locaux, Bordeaux', TRUE),
    (1, 'Fête des 20 ans Vite & Gourmand', 'Deux décennies de passion', 'party', 150, '2021-03-15', 'Darwin Ecosystème, Bordeaux', TRUE),

    -- More recent 2025 events for volume
    (1, 'Brunch Dominical Association Parents', 'Brunch convivial mensuel', 'brunch', 40, '2025-08-10', 'Parc Bordelais', TRUE),
    (1, 'Mariage Chen-Nguyen', 'Mariage multiculturel', 'wedding', 180, '2025-07-26', 'Château Les Carmes Haut-Brion', TRUE),
    (1, 'Team Building Société Générale', 'Atelier cuisine et dégustation', 'corporate', 30, '2025-06-15', 'Nos locaux, Bordeaux', TRUE),
    (1, 'Fiançailles Schmidt', 'Soirée intime de fiançailles', 'engagement', 25, '2025-05-20', 'Villa privée, Arcachon', FALSE),
    (1, 'Communion Solennelle Thomas', 'Déjeuner après cérémonie', 'communion', 55, '2025-05-04', 'Salle paroissiale, Gradignan', TRUE),
    (1, 'Cocktail Vernissage Galerie d''Art', 'Exposition artiste local', 'cultural', 70, '2025-04-12', 'Galerie des Chartrons, Bordeaux', TRUE),
    (1, 'Mariage en Petit Comité', 'Mariage intimiste', 'wedding', 20, '2025-03-22', 'Mairie de Bordeaux + restaurant privé', TRUE),
    (1, 'Pot de Départ à la Retraite', 'Célébration carrière', 'corporate', 50, '2025-02-28', 'Entreprise Dassault, Mérignac', TRUE),
    (1, 'Buffet Saint-Valentin', 'Menu romantique pour couples', 'party', 40, '2025-02-14', 'Restaurant éphémère, Bordeaux', TRUE),

    -- Events for 2020-2021 (COVID period, smaller)
    (1, 'Mariage Intime COVID', 'Mariage restreint période sanitaire', 'wedding', 30, '2020-08-15', 'Mairie + domicile, Bordeaux', TRUE),
    (1, 'Repas de Noël Adapté', 'Plateaux individuels livrés', 'corporate', 80, '2020-12-18', 'Livraison bureaux, Bordeaux métropole', TRUE),

    -- More historical variety
    (1, 'Banquet Centenaire Club Rugby', 'Célébration sportive', 'sports', 250, '2015-11-21', 'Stade Chaban-Delmas', TRUE),
    (1, 'Gala de Bienfaisance Rotary', 'Dîner caritatif annuel', 'charity', 180, '2018-04-07', 'Hôtel Intercontinental, Bordeaux', TRUE),
    (1, 'Festival Gastronomique', 'Participation événement local', 'cultural', 500, '2019-09-14', 'Place des Quinconces', TRUE),
    (1, 'Mariage VIP Personnalité', 'Événement haut de gamme confidentiel', 'wedding', 80, '2017-06-24', 'Location confidentielle', FALSE)
ON CONFLICT DO NOTHING;
