-- Menus reference diet(1-6), theme(1-10), created_by user(2=josé)
INSERT INTO "Menu" ("title","description","conditions","person_min","price_per_person","remaining_qty","status","diet_id","theme_id","created_by","published_at") VALUES
    -- Original 10 menus (IDs 1-10)
    ('Menu Prestige Mariage','Notre menu signature pour les mariages','Commander 14j avant. Matériel prêté.',50,85.00,10,'published',1,1,2,NOW()),
    ('Menu Végétarien Élégant','Alternative végétarienne raffinée','Commander 7j avant.',20,65.00,15,'published',2,1,2,NOW()),
    ('Cocktail Entreprise','Assortiment de canapés et mignardises','Commander 7j avant. Minimum 30 personnes.',30,45.00,20,'published',1,4,2,NOW()),
    ('Brunch Dominical','Formule brunch complète','Commander 5j avant.',15,35.00,25,'published',1,8,2,NOW()),
    ('Menu Gastronomique','Expérience culinaire 5 services','Commander 21j avant. Matériel prêté.',10,120.00,8,'published',1,6,2,NOW()),
    ('Barbecue Festif','Viandes grillées, salades, desserts','Commander 7j avant.',25,40.00,18,'published',1,7,2,NOW()),
    ('Menu Végan Découverte','100% végétal, saveurs du monde','Commander 7j avant.',15,55.00,12,'published',3,5,3,NOW()),
    ('Menu Noël Traditionnel','Repas de fêtes traditionnel français','Commander 14j avant.',20,95.00,10,'published',1,9,2,NOW()),
    ('Menu Pâques','Repas de Pâques printanier','Commander 10j avant.',15,75.00,15,'published',1,10,2,NOW()),
    ('Menu Brouillon Test','Menu en cours de préparation',NULL,10,50.00,5,'draft',1,2,2,NULL),
    
    -- French Classics (IDs 11-15)
    ('Coq au Vin Bourguignon','Poulet mijoté au vin rouge de Bourgogne','Commander 5j avant.',8,42.00,20,'published',1,6,2,NOW()),
    ('Boeuf Bourguignon Festif','Boeuf braisé, champignons, lardons','Commander 5j avant.',10,48.00,18,'published',1,2,2,NOW()),
    ('Cassoulet Toulousain','Haricots blancs, confit de canard, saucisses','Commander 7j avant.',12,38.00,15,'published',1,7,2,NOW()),
    ('Blanquette de Veau','Veau en sauce crémeuse aux légumes','Commander 5j avant.',8,45.00,20,'published',1,6,2,NOW()),
    ('Bouillabaisse Marseillaise','Soupe de poissons de roche traditionnelle','Commander 7j avant. Poissons frais.',15,65.00,12,'published',1,6,2,NOW()),
    
    -- Mediterranean (IDs 16-20)
    ('Paella Valenciana','Riz safrané, fruits de mer, chorizo','Commander 5j avant.',20,35.00,25,'published',1,7,2,NOW()),
    ('Mezzé Libanais','Assortiment de spécialités libanaises','Commander 3j avant.',15,32.00,30,'published',2,5,2,NOW()),
    ('Tajine d''Agneau','Agneau aux abricots et amandes','Commander 5j avant.',12,42.00,18,'published',5,6,2,NOW()),
    ('Moussaka Grecque','Gratin d''aubergines à la viande','Commander 5j avant.',15,36.00,20,'published',1,2,2,NOW()),
    ('Antipasti Italien','Charcuteries, fromages, légumes marinés','Commander 3j avant.',20,38.00,25,'published',1,5,2,NOW()),
    
    -- Asian Fusion (IDs 21-25)
    ('Sushi & Sashimi Premium','Assortiment de poissons crus japonais','Commander 3j avant. Poissons frais.',15,55.00,15,'published',1,6,2,NOW()),
    ('Dim Sum Cantonais','Raviolis vapeur et frits variés','Commander 3j avant.',20,28.00,30,'published',1,5,2,NOW()),
    ('Pad Thai Royal','Nouilles sautées aux crevettes','Commander 3j avant.',15,32.00,25,'published',1,5,2,NOW()),
    ('Bibimbap Coréen','Bol de riz, légumes, boeuf mariné','Commander 3j avant.',12,30.00,25,'published',1,5,2,NOW()),
    ('Curry Indien Végétarien','Curry de légumes aux épices','Commander 3j avant.',15,28.00,30,'published',2,5,2,NOW()),
    
    -- Special Occasions (IDs 26-30)
    ('Menu Baptême Classique','Repas traditionnel de baptême','Commander 10j avant.',30,55.00,15,'published',1,3,2,NOW()),
    ('Menu Anniversaire 50 ans','Repas festif pour anniversaire','Commander 7j avant.',25,62.00,18,'published',1,2,2,NOW()),
    ('Menu Saint-Valentin','Dîner romantique aux chandelles','Commander 5j avant. Menu couple.',2,95.00,20,'published',1,6,2,NOW()),
    ('Menu Nouvel An','Repas de réveillon du 31 décembre','Commander 14j avant.',20,110.00,10,'published',1,9,2,NOW()),
    ('Menu Communion','Repas de première communion','Commander 10j avant.',25,52.00,15,'published',1,3,2,NOW()),
    
    -- Healthy & Diet Options (IDs 31-35)
    ('Menu Sans Gluten Gourmet','Repas raffiné 100% sans gluten','Commander 5j avant.',10,58.00,15,'published',4,6,2,NOW()),
    ('Menu Halal Prestige','Menu halal haut de gamme','Commander 7j avant.',20,68.00,12,'published',5,1,2,NOW()),
    ('Menu Casher Traditionnel','Repas casher authentique','Commander 10j avant.',15,72.00,10,'published',6,6,2,NOW()),
    ('Buddha Bowl Party','Bols healthy et colorés','Commander 3j avant.',15,35.00,25,'published',3,5,3,NOW()),
    ('Brunch Végan Festif','Brunch 100% végétal gourmand','Commander 5j avant.',12,42.00,20,'published',3,8,3,NOW());
