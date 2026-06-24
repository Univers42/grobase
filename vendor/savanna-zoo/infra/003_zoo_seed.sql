-- ============================================================
-- 003_zoo_seed.sql — Savanna Park Zoo: complete seed data
-- ============================================================
SET search_path
TO public;

-- ── Staff (5) ─────────────────────────────────────────────────
INSERT INTO staff
  (id, email, full_name, role, zone, phone, hired_at)
VALUES
  ('b1000000-0000-0000-0000-000000000001', 'sophie.laurent@savanna-zoo.com', 'Sophie Laurent', 'admin', NULL, '+33 6 12 34 56 78', '2015-03-01'),
  ('b1000000-0000-0000-0000-000000000002', 'marcus.osei@savanna-zoo.com', 'Marcus Osei', 'zookeeper', 'savannah', '+33 6 23 45 67 89', '2017-06-15'),
  ('b1000000-0000-0000-0000-000000000003', 'elena.moreau@savanna-zoo.com', 'Elena Moreau', 'zookeeper', 'aquarium', '+33 6 34 56 78 90', '2018-09-01'),
  ('b1000000-0000-0000-0000-000000000004', 'yuki.tanaka@savanna-zoo.com', 'Dr. Yuki Tanaka', 'vet', NULL, '+33 6 45 67 89 01', '2019-01-10'),
  ('b1000000-0000-0000-0000-000000000005', 'lucas.petit@savanna-zoo.com', 'Lucas Petit', 'reception', NULL, '+33 6 56 78 90 12', '2021-04-20')
ON CONFLICT
(id) DO NOTHING;

-- ── Ticket Types (5) ──────────────────────────────────────────
INSERT INTO ticket_types
  (id, name, price_eur, description, color, max_per_day)
VALUES
  ('a1000000-0000-0000-0000-000000000001', 'Adult', 24.90, 'Standard adult entry (13+)', '#1a3a2a', 500),
  ('a1000000-0000-0000-0000-000000000002', 'Child', 14.90, 'Children aged 3-12. Under 3 free.', '#4a9e6f', 300),
  ('a1000000-0000-0000-0000-000000000003', 'Senior', 18.90, 'Visitors aged 65+', '#8b7355', 200),
  ('a1000000-0000-0000-0000-000000000004', 'VIP', 79.90, 'Skip-the-line + behind-the-scenes', '#c4702a', 30),
  ('a1000000-0000-0000-0000-000000000005', 'Family', 64.90, '2 adults + up to 3 children', '#2c6e49', 150)
ON CONFLICT
(id) DO NOTHING;

-- ── Animals (12) ──────────────────────────────────────────────
INSERT INTO animals
  (id, name, species, common_name, zone, status, sex, date_of_birth, origin, weight_kg, height_cm, diet_type, conservation_status, description, fun_facts, feeding_schedule, is_featured, total_feedings, keeper_id)
VALUES

  -- Savannah
  ('a0000000-0000-0000-0000-000000000001', 'Kibo', 'Panthera leo', 'African Lion', 'savannah', 'active', 'male',
    '2016-03-15', 'Kenya', 186.5, 120, 'carnivore', 'VU',
    'Kibo is our magnificent male lion, named after the highest peak of Kilimanjaro. He arrived from the Nairobi Wildlife Conservancy as part of our international breeding program.',
    '["Kibo can roar loud enough to be heard 8km away","He sleeps up to 20 hours per day","His mane darkens with age — a sign of health and maturity"]',
    '[{"time":"08:00","food_type":"Raw beef","quantity_kg":6},{"time":"17:00","food_type":"Raw beef + supplements","quantity_kg":5}]',
    true, 2847, 'b1000000-0000-0000-0000-000000000002'),

  ('a0000000-0000-0000-0000-000000000002', 'Amara', 'Giraffa camelopardalis', 'Reticulated Giraffe', 'savannah', 'active', 'female',
    '2014-09-22', 'Tanzania', 830, 520, 'herbivore', 'VU',
    'Amara is our tallest resident at 5.2 meters. She was born at the Serengeti Research Centre and is beloved by our youngest visitors for her gentle curiosity.',
    '["Amara''s tongue is 45cm long and dark purple — protecting it from sunburn","She can run at 55km/h despite her height","Giraffes only need 5-30 minutes of sleep per day"]',
    '[{"time":"07:30","food_type":"Acacia leaves","quantity_kg":20},{"time":"12:00","food_type":"Mixed browse","quantity_kg":15},{"time":"16:30","food_type":"Pelleted feed + hay","quantity_kg":18}]',
    true, 3961, 'b1000000-0000-0000-0000-000000000002'),

  ('a0000000-0000-0000-0000-00000000000c', 'Zuri', 'Loxodonta africana', 'African Elephant', 'savannah', 'active', 'female',
    '2008-04-12', 'South Africa', 3200, 280, 'herbivore', 'VU',
    'Zuri, meaning "beautiful" in Swahili, is the gentle matriarch of our savannah. At 16 years old she leads our small herd with calm authority.',
    '["Zuri can recognize over 30 individual humans by scent","Elephants mourn their dead and revisit bones of fallen family members","She drinks up to 200 litres of water per day"]',
    '[{"time":"06:30","food_type":"Hay and grass","quantity_kg":50},{"time":"11:00","food_type":"Fruits and vegetables","quantity_kg":30},{"time":"17:00","food_type":"Browse and bark","quantity_kg":40}]',
    true, 5102, 'b1000000-0000-0000-0000-000000000002'),

  -- Aquarium
  ('a0000000-0000-0000-0000-000000000003', 'Nemo', 'Amphiprioninae', 'Clownfish', 'aquarium', 'active', 'male',
    '2022-01-10', 'Australia', 0.03, 8, 'omnivore', 'LC',
    'Found in the warm waters of our Great Barrier Reef exhibit. Nemo lives symbiotically with his sea anemone host in a stunning coral habitat.',
    '["Clownfish are immune to their anemone host''s venom","All clownfish are born male — the dominant one can become female","They are one of the few fish species that care for their eggs"]',
    '[{"time":"09:00","food_type":"Marine flakes","quantity_kg":0.001},{"time":"15:00","food_type":"Brine shrimp","quantity_kg":0.001}]',
    false, 1203, 'b1000000-0000-0000-0000-000000000003'),

  ('a0000000-0000-0000-0000-000000000009', 'Marina', 'Chelonia mydas', 'Green Sea Turtle', 'aquarium', 'active', 'female',
    '2005-06-18', 'Costa Rica', 160, 110, 'herbivore', 'EN',
    'Marina was rescued as a hatchling off the Pacific coast of Costa Rica after a nesting beach was destroyed by coastal development.',
    '["Green sea turtles can hold their breath for up to 5 hours while sleeping","Marina navigates using the Earth''s magnetic field","Sea turtles have been on Earth for over 110 million years"]',
    '[{"time":"08:00","food_type":"Seagrass and lettuce","quantity_kg":2.5},{"time":"14:00","food_type":"Algae and jellyfish","quantity_kg":2}]',
    false, 5730, 'b1000000-0000-0000-0000-000000000003'),

  -- Arctic
  ('a0000000-0000-0000-0000-000000000004', 'Glacier', 'Ursus maritimus', 'Polar Bear', 'arctic', 'active', 'female',
    '2011-12-01', 'Canada', 295, 110, 'carnivore', 'VU',
    'Glacier is our majestic polar bear, residing in our climate-controlled Arctic Tundra exhibit kept at -5°C.',
    '["Polar bear fur is transparent, not white — it reflects light","Glacier can swim continuously for 100km","Her paws are slightly webbed for swimming efficiency"]',
    '[{"time":"09:00","food_type":"Salmon + mackerel","quantity_kg":5},{"time":"14:00","food_type":"Herring + seal meat","quantity_kg":7}]',
    true, 4218, 'b1000000-0000-0000-0000-000000000002'),

  ('a0000000-0000-0000-0000-00000000000a', 'Frost', 'Aptenodytes patagonicus', 'King Penguin', 'arctic', 'active', 'male',
    '2019-07-04', 'Argentina', 14, 90, 'carnivore', 'LC',
    'Frost is the unofficial leader of our 12-strong king penguin colony. He arrived from the Patagonia Marine Research Station.',
    '["King penguins can dive to 300m depth","Frost can hold his breath for 7 minutes underwater","Penguins are monogamous — Frost has the same partner for 4 years running"]',
    '[{"time":"08:30","food_type":"Herring","quantity_kg":1.2},{"time":"14:30","food_type":"Squid + krill","quantity_kg":1}]',
    false, 1890, 'b1000000-0000-0000-0000-000000000003'),

  -- Rainforest
  ('a0000000-0000-0000-0000-000000000005', 'Balam', 'Panthera onca', 'Jaguar', 'rainforest', 'breeding', 'male',
    '2018-08-30', 'Brazil', 95, 75, 'carnivore', 'NT',
    'Balam ("jaguar" in Maya) was rescued from illegal wildlife trade in the Brazilian Amazon. He is currently in our breeding program.',
    '["Jaguars are the only big cats that roar AND purr","Balam''s bite force is the strongest of any big cat relative to size","Unlike most cats, jaguars love water and are excellent swimmers"]',
    '[{"time":"08:30","food_type":"Wild boar meat","quantity_kg":4},{"time":"18:00","food_type":"Chicken with bones","quantity_kg":3}]',
    true, 1876, 'b1000000-0000-0000-0000-000000000002'),

  ('a0000000-0000-0000-0000-000000000008', 'Canopy', 'Bradypus variegatus', 'Brown-throated Sloth', 'rainforest', 'active', 'female',
    '2020-02-14', 'Colombia', 4.5, 58, 'herbivore', 'LC',
    'Canopy is our beloved sloth, famous for spending exactly 15 hours per day sleeping.',
    '["Sloths only descend to the ground once a week — to defecate","Canopy can rotate her head 270° thanks to extra neck vertebrae","Algae grows on her fur, providing natural camouflage"]',
    '[{"time":"10:00","food_type":"Cecropia leaves","quantity_kg":0.3},{"time":"16:00","food_type":"Hibiscus flowers","quantity_kg":0.2}]',
    false, 1462, 'b1000000-0000-0000-0000-000000000002'),

  -- Reptile
  ('a0000000-0000-0000-0000-000000000006', 'Sobek', 'Crocodylus niloticus', 'Nile Crocodile', 'reptile', 'active', 'male',
    '2000-01-20', 'Egypt', 410, 45, 'carnivore', 'LC',
    'Named after the ancient Egyptian crocodile god, Sobek is our oldest reptile resident at 26 years old.',
    '["Nile crocodiles can live to be 100 years old","Sobek can go months without eating after a large meal","Crocodiles have the strongest bite force of any living animal — 3,700 PSI"]',
    '[{"time":"11:00","food_type":"Whole chicken","quantity_kg":5}]',
    false, 3150, 'b1000000-0000-0000-0000-000000000003'),

  -- Aviary
  ('a0000000-0000-0000-0000-000000000007', 'Phoenix', 'Phoenicopterus roseus', 'Greater Flamingo', 'aviary', 'active', 'female',
    '2017-11-05', 'France', 3.5, 140, 'omnivore', 'LC',
    'Phoenix is the lead bird in our flock of 28 greater flamingos.',
    '["Flamingos can only eat with their heads upside-down","Phoenix sleeps standing on one leg — scientists still debate why","Flamingo flocks can number in the hundreds of thousands in the wild"]',
    '[{"time":"07:30","food_type":"Brine shrimp + algae pellets","quantity_kg":0.5},{"time":"15:00","food_type":"Spirulina mix","quantity_kg":0.3}]',
    false, 2580, 'b1000000-0000-0000-0000-000000000003'),

  -- Petting Zoo
  ('a0000000-0000-0000-0000-00000000000b', 'Clover', 'Oryctolagus cuniculus', 'Holland Lop Rabbit', 'petting', 'active', 'female',
    '2023-03-01', 'Netherlands', 1.8, 25, 'herbivore', 'LC',
    'Clover is the star of our Petting Zone — a fluffy holland lop with floppy ears and a calm temperament.',
    '["Rabbits can see nearly 360° without moving their head","Clover ''binkies'' (jumps and twists mid-air) when she''s happy","A rabbit''s teeth never stop growing — she chews hay to keep them trimmed"]',
    '[{"time":"08:00","food_type":"Timothy hay","quantity_kg":0.15},{"time":"12:00","food_type":"Fresh greens","quantity_kg":0.1},{"time":"17:00","food_type":"Pellets + carrot","quantity_kg":0.08}]',
    false, 920, 'b1000000-0000-0000-0000-000000000002')

ON CONFLICT
(id) DO NOTHING;

-- ── Events (6) ────────────────────────────────────────────────
INSERT INTO events
  (id, title, type, zone, host, start_at, end_at, capacity, registrations, price_eur, is_free, is_active, is_full, description)
VALUES
  ('e0000000-0000-0000-0000-000000000001',
    'Lion''s Lunch — Live Feeding Show', 'feeding_show', 'savannah', 'Marcus Osei',
    now() + interval
'3 days' + interval '11 hours',
 now
() + interval '3 days' + interval '11 hours 45 minutes',
 80, 62, 0, true, true, false,
 'Watch Kibo devour 6 kg of raw beef while our keeper Marcus explains the hunting strategies of African lions.'),

('e0000000-0000-0000-0000-000000000002',
 'Midnight Safari — After-Dark Experience', 'night_safari', 'savannah', 'Sophie Laurent',
 now
() + interval '7 days' + interval '20 hours 30 minutes',
 now
() + interval '7 days' + interval '23 hours',
 40, 38, 39.90, false, true, false,
 'Experience the zoo after sunset as nocturnal animals awaken. LED-lit trails, night-vision binoculars, and hot-chocolate station.'),

('e0000000-0000-0000-0000-000000000003',
 'Junior Zookeeper for a Day', 'kids_workshop', 'petting', 'Elena Moreau',
 now
() + interval '10 days' + interval '9 hours',
 now
() + interval '10 days' + interval '16 hours',
 20, 20, 29.90, false, true, true,
 'Children aged 6-12 join our team for a full-day immersion. They help prepare meals, learn about enrichment, and receive a certificate.'),

('e0000000-0000-0000-0000-000000000004',
 'Behind the Ice — Polar Bear Guided Tour', 'guided_tour', 'arctic', 'Marcus Osei',
 now
() + interval '5 days' + interval '14 hours',
 now
() + interval '5 days' + interval '15 hours 30 minutes',
 25, 11, 24.90, false, true, false,
 'Step behind the scenes of our Arctic Tundra exhibit for a 90-minute guided tour. Meet Glacier up close from the keeper tunnel.'),

('e0000000-0000-0000-0000-000000000005',
 'Sunset VIP — Champagne & Conservation', 'vip_experience', 'savannah', 'Sophie Laurent',
 now
() + interval '14 days' + interval '18 hours 30 minutes',
 now
() + interval '14 days' + interval '21 hours',
 12, 5, 149.90, false, true, false,
 'An exclusive evening for up to 12 guests — private access to the Savannah overlook with champagne and a personal guide.'),

('e0000000-0000-0000-0000-000000000006',
 'Ocean Depths — Aquarium Feeding Dive', 'feeding_show', 'aquarium', 'Elena Moreau',
 now
() + interval '2 days' + interval '10 hours 30 minutes',
 now
() + interval '2 days' + interval '11 hours 15 minutes',
 60, 45, 0, true, true, false,
 'Our aquarium keeper Elena dives into the main reef tank to hand-feed the sea turtles and stingrays.')

ON CONFLICT
(id) DO NOTHING;

-- ── Visitor Messages (10) ─────────────────────────────────────
INSERT INTO visitor_messages
  (visitor_name, email, subject, message, status, reply, replied_at, created_at, updated_at)
VALUES
  ('Claire Dupont', 'claire.dupont@example.com', 'Birthday party for my daughter',
    'Hello! My daughter turns 8 next month and she''s obsessed with the penguins. Do you offer private birthday party packages near the Arctic exhibit?',
    'replied',
    'Dear Claire, we would love to host your daughter''s birthday! Our "Arctic Party" package includes 2 hours in the penguin pavilion, a keeper talk, and a birthday cake. — Sophie',
    now() - interval
'2 days', now
() - interval '5 days', now
() - interval '2 days'),

('Thomas Wagner', 'thomas.w@example.com', 'Accessibility question',
 'Hi, my mother uses a wheelchair. Are all outdoor paths accessible? Is the Rainforest Dome wheelchair-friendly?',
 'replied',
 'Hello Thomas, all main paths are fully wheelchair-accessible including the Rainforest Dome (ramp entrance on the east side). — Lucas',
 now
() - interval '1 day', now
() - interval '3 days', now
() - interval '1 day'),

('Amélie Martin', 'amelie.martin@example.com', 'Lost teddy bear!',
 'My son left his stuffed lion toy near the savannah viewing deck yesterday. It''s brown with a red bow. He''s very upset — any chance your team found it?',
 'read', NULL, NULL, now
() - interval '1 day', now
()),

('Jake Peterson', 'jake.peterson@example.com', 'Photography permit',
 'I''m a freelance wildlife photographer and I''d love to do a professional shoot at the zoo. Do you offer photography permits or early-morning access?',
 'unread', NULL, NULL, now
() - interval '2 hours', now
() - interval '2 hours'),

('Sofia Rossi', 'sofia.rossi@example.com', 'School group visit — 45 students',
 'I''m a primary school teacher and we''d like an educational visit for 45 students (ages 9-10) in October. Do you have a guided programme?',
 'replied',
 'Dear Sofia, our "Classroom in the Wild" programme is perfect! Includes a 2-hour guided tour and species worksheets. Group rate is €8.50 per student. — Sophie',
 now
() - interval '4 days', now
() - interval '7 days', now
() - interval '4 days'),

('Omar Benali', 'omar.benali@example.com', 'Volunteer programme',
 'I''m a biology student looking for a volunteer or internship position at the zoo for the summer. I have experience with reptile husbandry.',
 'read', NULL, NULL, now
() - interval '2 days', now
() - interval '1 day'),

('Hannah Kim', 'hannah.kim@example.com', 'Vegan food options?',
 'We''re a family of four and we''re all vegan. What food options are available at the on-site cafe?',
 'replied',
 'Hi Hannah! Our café now offers a dedicated plant-based menu including a vegan burger, falafel wrap, acai bowl, and oat-milk lattes! — Lucas',
 now
() - interval '6 days', now
() - interval '8 days', now
() - interval '6 days'),

('Marcel Fontaine', 'marcel.fontaine@example.com', 'Complaint — rude staff at ticket booth',
 'I visited on Sunday and the person at the main ticket booth was incredibly rude when I asked about the senior discount. I''ve been visiting for 30 years.',
 'unread', NULL, NULL, now
() - interval '3 hours', now
() - interval '3 hours'),

('Elena Vasquez', 'elena.vasquez@example.com', 'Adopting an animal symbolically',
 'I''d love to symbolically adopt Kibo the lion for my boyfriend''s birthday. What are the different tiers?',
 'replied',
 'Hello Elena! Our adoption tiers: Bronze (€30 — certificate + photo), Silver (€60 — plus plush toy), Gold (€120 — plus a private keeper encounter). — Sophie',
 now
() - interval '3 days', now
() - interval '5 days', now
() - interval '3 days'),

('Liam O''Brien', 'liam.obrien@example.com', 'Parking situation',
 'Is there a bigger parking lot planned? Last two visits we parked on the street 500m away. With two small kids and a stroller it''s a nightmare.',
 'archived', NULL, NULL, now
() - interval '30 days', now
() - interval '25 days');

-- ── Tickets (~210 over 30 days) ───────────────────────────────
WITH names(idx, vname, vemail) AS (
    VALUES
(0, 'Alice Martin',    'alice.m@example.com'),
(1, 'Bob Dupont',      'bob.d@example.com'),
(2, 'Chloé Bernard',   'chloe.b@example.com'),
(3, 'David Leroy',     'david.l@example.com'),
(4, 'Emma Moreau',     'emma.m@example.com'),
(5, 'François Petit',  'francois.p@example.com'),
(6, 'Gabrielle Roux',  'gabrielle.r@example.com')
),
day_series AS
(
    SELECT d::date AS visit_date
FROM generate_series(current_date - 29, current_date, '1 day') AS d
)
,
tickets_per_day AS
(
    SELECT d.visit_date, n.idx AS slot, n.vname, n.vemail
FROM day_series d CROSS JOIN names n
)
,
type_cycle
(slot_mod, type_id, qty, unit_price) AS
(
    VALUES
(0, 'a1000000-0000-0000-0000-000000000001'::uuid, 1, 24.90),
(1, 'a1000000-0000-0000-0000-000000000002'::uuid, 2, 14.90),
(2, 'a1000000-0000-0000-0000-000000000003'::uuid, 1, 18.90),
(3, 'a1000000-0000-0000-0000-000000000004'::uuid, 1, 79.90),
(4, 'a1000000-0000-0000-0000-000000000005'::uuid, 1, 64.90),
(5, 'a1000000-0000-0000-0000-000000000001'::uuid, 2, 24.90),
(6, 'a1000000-0000-0000-0000-000000000002'::uuid, 3, 14.90)
)
INSERT INTO tickets
  (ticket_type_id, visitor_name, visitor_email, visit_date, quantity, total_eur, sold_by, status)
SELECT
  tc.type_id, tp.vname, tp.vemail, tp.visit_date, tc.qty,
  tc.qty * tc.unit_price,
  CASE WHEN tp.slot < 5
         THEN 'b1000000-0000-0000-0000-000000000005'::uuid
         ELSE 'b1000000-0000-0000-0000-000000000001'
::uuid
END,
    CASE WHEN tp.visit_date < current_date THEN 'used'
         ELSE 'valid'
END
FROM tickets_per_day tp
JOIN type_cycle tc ON tc.slot_mod = tp.slot;
