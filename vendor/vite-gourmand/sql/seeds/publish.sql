-- ============================================
-- SEED: Publish (Customer Reviews)
-- ============================================
-- Realistic reviews from customers after their events
-- Users: 8=alice, 9=bob, 10=claire, 11=david, 12=emma, 
--        13=francois, 14=helene, 15=igor, 16=julie.client, 
--        17=karim, 18=laura, 19=nicolas
-- Status: approved (visible), pending (awaiting moderation), rejected
-- Note: 1-5 stars (subject requirement)
-- ============================================

INSERT INTO "Publish" ("user_id", "order_id", "note", "description", "status") VALUES
    -- ═══ APPROVED REVIEWS (visible on homepage) ═══
    -- 5-star reviews
    (8, 1, 5, 'Service impeccable pour notre mariage ! José et son équipe ont su créer une atmosphère magique. Les plats étaient raffinés, le service discret et efficace. Nos 120 invités ont été enchantés. Merci pour ce moment inoubliable !', 'approved'),
    (9, 2, 5, 'Nous avons fait appel à Vite & Gourmand pour le cocktail de notre entreprise. Professionnalisme exemplaire, mets délicieux et présentation soignée. Tous nos collaborateurs ont été impressionnés.', 'approved'),
    (11, NULL, 5, 'Le brunch dominical commandé pour notre réunion familiale était parfait ! Quantités généreuses, produits frais, et Julie a même ajouté une petite touche personnalisée pour l''anniversaire de ma mère. Bravo !', 'approved'),
    (8, NULL, 5, 'Après notre mariage, nous avons recontacté Vite & Gourmand pour le baptême de notre fils. Menu gastronomique exceptionnel, aussi bon que la première fois. Fidèles clients désormais !', 'approved'),
    (12, 11, 5, 'Événement d''entreprise à Toulouse : tout était délicieux ! Le chef s''est déplacé personnellement. Les amuse-bouches au foie gras ont fait sensation. Service irréprochable du début à la fin.', 'approved'),
    (19, 19, 5, 'Client fidèle depuis 5 ans, jamais déçu. Pour notre réception de Pâques, le menu était parfaitement équilibré. L''équipe connaît nos goûts et s''adapte toujours avec brio.', 'approved'),
    (16, NULL, 5, 'Brunch parfait pour mon anniversaire surprise ! Tout était prêt à l''heure, les viennoiseries étaient fraîches et les œufs Bénédicte à tomber. Mes amis m''en reparlent encore !', 'approved'),
    (11, NULL, 5, 'Le menu gastronomique 5 services est une tuerie. Chaque plat était une œuvre d''art. Le homard bleu rôti reste gravé dans ma mémoire. Prix justifié par la qualité exceptionnelle.', 'approved'),

    -- 4-star reviews  
    (9, NULL, 4, 'Cocktail entreprise très réussi. Seul petit bémol : quelques canapés étaient un peu tièdes à l''arrivée. Mais le goût était au rendez-vous et l''équipe très réactive.', 'approved'),
    (13, 12, 4, 'Le foie gras maison était exceptionnel, vraiment le meilleur que j''ai goûté. Le reste du menu était très bon sans être extraordinaire. Rapport qualité-prix correct.', 'approved'),
    (19, 20, 4, 'Petit événement de 15 personnes mais grande qualité. Seule suggestion : proposer plus d''options végétariennes pour les prochains menus.', 'approved'),
    (15, NULL, 4, 'Menu mariage de bonne qualité. Service ponctuel et professionnel. La présentation était soignée. Juste une légère attente entre les plats principaux et le dessert.', 'approved'),

    -- ═══ PENDING REVIEWS (awaiting moderation) ═══
    (10, NULL, 3, 'Bon service global mais la livraison avait 30 minutes de retard. Les plats étaient bons mais auraient été meilleurs chauds. Dommage car le goût y était.', 'pending'),
    (14, NULL, 3, 'Portions un peu justes pour un buffet d''entreprise. 2-3 personnes n''ont pas pu se resservir. La qualité était là mais attention aux quantités.', 'pending'),
    (18, NULL, 4, 'Bonne expérience globale pour notre séminaire. Organisation fluide, équipe souriante. Le dessert chocolat était divin !', 'pending'),

    -- ═══ REJECTED REVIEWS (inappropriate/spam) ═══
    (11, NULL, 2, 'Qualité en dessous de mes attentes cette fois-ci. Peut-être un jour de moins bien ? Je retenterai car mes expériences précédentes étaient excellentes.', 'rejected'),
    (17, NULL, 1, 'Commande annulée sans explication claire. Très mécontent du manque de communication. MAJ: Après discussion, c''était un problème technique, ils m''ont remboursé intégralement.', 'rejected')
ON CONFLICT DO NOTHING;
