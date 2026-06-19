-- ============================================
-- SEED: CompanyWorkingHours (M:N junction)
-- ============================================
-- Links the company to its working hours
-- WorkingHours IDs: 1=Lundi, 2=Mardi, ..., 7=Dimanche
-- ============================================

INSERT INTO "CompanyWorkingHours" ("company_id", "working_hours_id") VALUES
    (1, 1),  -- Lundi
    (1, 2),  -- Mardi
    (1, 3),  -- Mercredi
    (1, 4),  -- Jeudi
    (1, 5),  -- Vendredi
    (1, 6),  -- Samedi
    (1, 7)   -- Dimanche
ON CONFLICT DO NOTHING;
