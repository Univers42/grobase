INSERT INTO "Message" ("sender_id","recipient_id","subject","body","priority","is_read") VALUES
    (2,4,'Commande urgente','Pierre, commande pour 100 personnes.','urgent',FALSE),
    (4,2,'RE: Commande urgente','C''est noté José.','normal',TRUE),
    (5,2,'Stock bas champignons','Moins de 3 kg. Faut-il commander ?','high',FALSE),
    (2,5,'RE: Stock champignons','Oui, commande 20 kg.','normal',TRUE),
    (3,4,'Nouveau menu végan','Peux-tu relire le menu ?','normal',FALSE),
    (2,7,'Bienvenue','Bienvenue Lucie !','normal',TRUE),
    (7,2,'RE: Bienvenue','Merci José !','normal',TRUE),
    (4,5,'Planning semaine','5 commandes mardi. Tu gères ?','high',FALSE),
    (5,4,'RE: Planning','Pas de souci, dès 6h.','normal',TRUE),
    (4,2,'Matériel manquant','3 chafing dishes manquants pour ORD-2026-00014.','urgent',FALSE);
