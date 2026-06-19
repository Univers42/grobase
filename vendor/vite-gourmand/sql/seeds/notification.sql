INSERT INTO "Notification" ("user_id","type","title","body","link_url","is_read") VALUES
    (8,'order_update','Commande livrée','Votre commande ORD-2026-00001 a été livrée.','/orders/1',TRUE),
    (8,'review','Laissez un avis','Partagez votre expérience !','/reviews/new?order=1',FALSE),
    (9,'order_update','Commande livrée','Votre commande ORD-2026-00002 a été livrée.','/orders/2',TRUE),
    (4,'system','Nouvelle commande','Commande ORD-2026-00009 à traiter.','/admin/orders/9',FALSE),
    (11,'promo','Code promo !','Utilisez BIENVENUE10 pour 10% de réduction.','/menus',FALSE),
    (10,'order_update','Commande annulée','Votre commande ORD-2026-00008 a été annulée.','/orders/8',TRUE),
    (2,'system','Stock bas','Foie Gras en dessous du seuil.','/admin/ingredients',FALSE),
    (12,'order_update','Commande terminée','Votre commande ORD-2026-00011 est terminée.','/orders/11',TRUE),
    (17,'order_update','Commande annulée','Votre commande a été annulée par l''équipe.','/orders/16',TRUE),
    (19,'promo','Merci fidèle client !','Profitez de FIDELE50.','/menus',FALSE);
