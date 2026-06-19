INSERT INTO "WorkingHours" ("day", "opening", "closing") VALUES
    ('Lundi',    '09:00', '18:00'),
    ('Mardi',    '09:00', '18:00'),
    ('Mercredi', '09:00', '18:00'),
    ('Jeudi',    '09:00', '18:00'),
    ('Vendredi', '09:00', '20:00'),
    ('Samedi',   '10:00', '22:00'),
    ('Dimanche', '10:00', '16:00')
ON CONFLICT ("day") DO NOTHING;
