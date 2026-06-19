-- ============================================
-- SEED: Company (Vite & Gourmand)
-- ============================================
-- The main catering company. Can be extended for multi-company support.
-- ============================================

INSERT INTO "Company" (
    "name", "slogan", "description", 
    "first_opening_date", "address", "city", "postal_code", "country",
    "phone", "email", "website", "siret", "logo_url", "is_active"
) VALUES
    (
        'Vite & Gourmand',
        'Traiteur d''exception pour tous vos événements',
        'Depuis 2001, Vite & Gourmand propose une cuisine raffinée et créative pour sublimer tous vos événements. Mariages, réceptions d''entreprise, anniversaires... Notre équipe passionnée met son savoir-faire au service de vos moments les plus précieux.',
        '2001-03-15',
        '15 Rue Sainte-Catherine',
        'Bordeaux',
        '33000',
        'France',
        '05 56 00 00 00',
        'contact@vite-gourmand.fr',
        'https://vite-gourmand.fr',
        '12345678901234',
        '/img/logo/vite-gourmand.png',
        TRUE
    )
ON CONFLICT DO NOTHING;
