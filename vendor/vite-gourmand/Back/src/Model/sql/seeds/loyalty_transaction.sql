INSERT INTO "LoyaltyTransaction" ("loyalty_account_id","order_id","points","type","description") VALUES
    (1,1,4500,'earn','Commande ORD-2026-00001 livrée'),
    (1,NULL,-500,'redeem','Réduction appliquée sur ORD-2026-00005'),
    (2,2,1800,'earn','Commande ORD-2026-00002 livrée'),
    (3,NULL,2200,'earn','Cumul commandes 2025'),
    (3,20,1300,'earn','Commande ORD-2026-00020 livrée'),
    (3,NULL,-1000,'redeem','Réduction fidélité'),
    (4,11,1500,'earn','Commande ORD-2026-00011 livrée'),
    (5,12,2800,'earn','Commande ORD-2026-00012 livrée'),
    (5,NULL,-500,'redeem','Code FIDELE50 appliqué'),
    (6,19,2600,'earn','Commande ORD-2026-00019 livrée'),
    (6,NULL,-2000,'redeem','Réduction appliquée'),
    (6,NULL,2000,'bonus','Bonus fidélité VIP');
