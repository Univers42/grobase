-- ============================================
-- FIX: Update all test user passwords
-- ============================================
-- The original seed used a well-known example bcrypt hash
-- that did NOT actually match "Test123!".
-- This script updates all seeded users to the correct hash.
--
-- Password: Test123!
-- Hash: $2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy
-- Salt rounds: 12 (matches SALT_ROUNDS in password.service.ts)
-- ============================================

UPDATE "User"
SET "password" = '$2b$12$MWH9rseagWuts0bxu0i1TebV2xO9DU50WYtAXNQL6GoFYClhrG4Gy'
WHERE "email" IN (
    'dylan@vitegourmand.dev',
    'jose@vitegourmand.fr',
    'julie@vitegourmand.fr',
    'pierre@vitegourmand.fr',
    'sophie@vitegourmand.fr',
    'marc@vitegourmand.fr',
    'lucie@vitegourmand.fr',
    'alice@example.fr',
    'bob@example.fr',
    'claire@example.fr',
    'david@example.fr',
    'emma@example.fr',
    'francois@example.fr',
    'helene@example.fr',
    'igor@example.fr',
    'julie.client@example.fr',
    'karim@example.fr',
    'laura@example.fr',
    'nicolas@example.fr',
    'deleted.user@example.fr'
);
