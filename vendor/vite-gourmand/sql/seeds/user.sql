-- ============================================
-- SEED: Users (20 test users — all roles)
-- ============================================
-- Password for ALL test users: Test123!
-- Bcrypt hash ($2b$12$) generated offline.
-- DO NOT use these in production.
-- ============================================

-- ============================================
-- ALL passwords: Test123!
-- Bcrypt hash: $2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy
-- Generated with: bcrypt.hash('Test123!', 12)  (matches SALT_ROUNDS=12 in password.service.ts)
-- ============================================

INSERT INTO "User" (
    "email","password","first_name","last_name",
    "phone_number","city","country","postal_code",
    "role_id","is_active","is_email_verified",
    "gdpr_consent","gdpr_consent_date"
) VALUES
    -- 1: superadmin
    ('dylan@vitegourmand.dev',
     '$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Dylan','Lesieur','+33600000000','Bordeaux','France','33000',
     1,TRUE,TRUE,TRUE,NOW()),
    -- 2: admin (José)
    ('jose@vitegourmand.fr',
     '$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'José','Garcia','+33600000001','Bordeaux','France','33000',
     2,TRUE,TRUE,TRUE,NOW()),
    -- 3: admin (Julie)
    ('julie@vitegourmand.fr',
     '$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Julie','Dupont','+33600000002','Bordeaux','France','33000',
     2,TRUE,TRUE,TRUE,NOW()),
    -- 4: employee
    ('pierre@vitegourmand.fr',
     '$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Pierre','Martin','+33600000003','Bordeaux','France','33000',
     3,TRUE,TRUE,TRUE,NOW()),
    -- 5: employee
    ('sophie@vitegourmand.fr',
     '$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Sophie','Bernard','+33600000004','Bordeaux','France','33000',
     3,TRUE,TRUE,TRUE,NOW()),
    -- 6: employee (disabled)
    ('marc@vitegourmand.fr',
     '$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Marc','Lefèvre','+33600000005','Bordeaux','France','33000',
     3,FALSE,TRUE,TRUE,NOW()),
    -- 7: employee
    ('lucie@vitegourmand.fr',
     '$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Lucie','Fournier','+33600000006','Bordeaux','France','33000',
     3,TRUE,TRUE,TRUE,NOW()),
    -- 8-20: clients (utilisateur = role 4)
    ('alice@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Alice','Moreau','+33611111111','Paris','France','75001',4,TRUE,TRUE,TRUE,NOW()),
    ('bob@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Bob','Petit','+33622222222','Lyon','France','69001',4,TRUE,TRUE,TRUE,NOW()),
    ('claire@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Claire','Dubois','+33633333333','Marseille','France','13001',4,TRUE,TRUE,TRUE,NOW()),
    ('david@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'David','Roux','+33644444444','Bordeaux','France','33000',4,TRUE,TRUE,TRUE,NOW()),
    ('emma@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Emma','Leroy','+33655555555','Toulouse','France','31000',4,TRUE,TRUE,TRUE,NOW()),
    ('francois@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'François','Girard','+33666666666','Nice','France','06000',4,TRUE,TRUE,TRUE,NOW()),
    ('helene@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Hélène','Mercier','+33677777777','Nantes','France','44000',4,TRUE,FALSE,TRUE,NOW()),
    ('igor@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Igor','Blanc','+33688888888','Strasbourg','France','67000',4,TRUE,TRUE,TRUE,NOW()),
    ('julie.client@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Julie','Lambert','+33699999999','Montpellier','France','34000',4,TRUE,TRUE,TRUE,NOW()),
    ('karim@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Karim','Benali','+33610101010','Lille','France','59000',4,TRUE,TRUE,TRUE,NOW()),
    ('laura@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Laura','Fontaine','+33610201020','Rennes','France','35000',4,TRUE,TRUE,TRUE,NOW()),
    ('nicolas@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Nicolas','Chevalier','+33610301030','Bordeaux','France','33000',4,TRUE,TRUE,TRUE,NOW()),
    ('deleted.user@example.fr','$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy',
     'Utilisateur','Supprimé',NULL,NULL,'France',NULL,4,FALSE,FALSE,TRUE,'2025-06-01')
ON CONFLICT ("email") DO NOTHING;

UPDATE "User" SET "is_deleted"=TRUE,"deleted_at"='2025-12-01'
WHERE "email"='deleted.user@example.fr';
