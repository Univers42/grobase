-- ============================================
-- SEED: Promotions
-- ============================================
-- Realistic promotions for Vite & Gourmand traiteur
-- Discount IDs: 1=BIENVENUE10, 2=ETE2026, 3=FIDELE50, 4=EXPIRE2025, 5=NOEL2026
-- Created by: user 2 (José, admin)
-- ============================================

INSERT INTO "Promotion" ("title", "description", "short_text", "type", "image_url", "link_url", "link_label", "badge_text", "bg_color", "text_color", "discount_id", "priority", "is_active", "is_public", "start_date", "end_date", "created_by") VALUES

    -- 🔥 Active public banners (visible on site right now)
    (
        'Offre de Bienvenue -10%',
        'Nouveau client ? Profitez de 10% de réduction sur votre première commande avec le code BIENVENUE10. Valable sur tous nos menus traiteur.',
        '🎉 -10% sur votre 1ère commande · Code : BIENVENUE10',
        'banner',
        NULL,
        '/menu',
        'Voir nos menus',
        '-10%',
        '#722F37',
        '#FFFFFF',
        1,
        100,
        TRUE,
        TRUE,
        '2026-01-01 00:00:00',
        '2026-12-31 23:59:59',
        2
    ),
    (
        'Menu Printemps 2026',
        'Découvrez notre nouveau menu de saison : produits frais du marché, recettes printanières et saveurs légères. Asperges, fraises de Dordogne, agneau de Pauillac...',
        '🌸 Nouveau menu Printemps · Saveurs de saison dès maintenant !',
        'seasonal',
        'https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=800',
        '/menu',
        'Découvrir le menu',
        'NOUVEAU',
        '#556B2F',
        '#FFFFFF',
        NULL,
        90,
        TRUE,
        TRUE,
        '2026-02-01 00:00:00',
        '2026-05-31 23:59:59',
        2
    ),
    (
        'Vente Flash Saint-Valentin',
        'Menu romantique pour 2 à prix doux : apéritif, entrée, plat, dessert et une bouteille de champagne offerte. Livraison le 14 février.',
        '💕 Menu Saint-Valentin · Champagne offert avec le code ETE2026',
        'flash_sale',
        'https://images.unsplash.com/photo-1414235077428-338989a2e8c0?w=800',
        '/contact',
        'Réserver maintenant',
        '🔥 FLASH',
        '#D4AF37',
        '#1A1A1A',
        2,
        95,
        TRUE,
        TRUE,
        '2026-02-01 00:00:00',
        '2026-02-14 23:59:59',
        2
    ),

    -- 📢 Future promotions (not yet active, scheduled)
    (
        'Promo Été 2026 -15%',
        'Cet été, profitez de 15% de réduction sur tous nos menus cocktail et barbecue pour vos garden parties. Code : ETE2026.',
        '☀️ -15% sur les menus été · Code : ETE2026',
        'banner',
        'https://images.unsplash.com/photo-1555939594-58d7cb561ad1?w=800',
        '/menu',
        'Voir les menus été',
        '-15%',
        '#D4AF37',
        '#1A1A1A',
        2,
        80,
        TRUE,
        TRUE,
        '2026-06-01 00:00:00',
        '2026-08-31 23:59:59',
        2
    ),
    (
        'Noël Gourmand -20%',
        'Pour les fêtes de fin d''année, offrez-vous un menu d''exception. -20% avec le code NOEL2026 sur nos menus de Noël et Nouvel An.',
        '🎄 -20% menus de fêtes · Code : NOEL2026',
        'seasonal',
        NULL,
        '/menu',
        'Menu de Noël',
        '-20%',
        '#722F37',
        '#FFFFFF',
        5,
        85,
        TRUE,
        TRUE,
        '2026-12-01 00:00:00',
        '2026-12-25 23:59:59',
        2
    ),

    -- 🔒 Non-public promotions (targeted to specific users only)
    (
        'Fidélité VIP -50€',
        'Merci pour votre fidélité ! En tant que client privilégié, bénéficiez de 50€ de réduction sur votre prochaine commande de 500€ ou plus.',
        'Offre exclusive fidélité · -50€ dès 500€',
        'loyalty',
        NULL,
        '/menu',
        'En profiter',
        'VIP',
        '#1A1A1A',
        '#D4AF37',
        3,
        70,
        TRUE,
        FALSE,
        '2026-01-01 00:00:00',
        '2026-12-31 23:59:59',
        2
    ),

    -- ❌ Expired promotion (for history / demo)
    (
        'Soldes Janvier 2026',
        'Offre spéciale janvier : réductions sur les menus séminaire et conférence. Offre expirée.',
        'Offre terminée',
        'banner',
        NULL,
        '/menu',
        'Voir les menus',
        'TERMINÉ',
        '#666666',
        '#FFFFFF',
        NULL,
        0,
        FALSE,
        TRUE,
        '2026-01-02 00:00:00',
        '2026-01-31 23:59:59',
        2
    )

ON CONFLICT DO NOTHING;
