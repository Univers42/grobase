-- ============================================================
-- 002_seed_staff.sql — 5 staff members
-- ============================================================

INSERT INTO staff (id, email, full_name, role, zone, avatar_url, phone, hired_at) VALUES
(
    'b1000000-0000-0000-0000-000000000001',
    'sophie.laurent@savanna-zoo.com',
    'Sophie Laurent',
    'admin',
    NULL,
    '/storage/staff/sophie.jpg',
    '+33 6 12 34 56 78',
    '2015-03-01'
),
(
    'b1000000-0000-0000-0000-000000000002',
    'marcus.osei@savanna-zoo.com',
    'Marcus Osei',
    'zookeeper',
    'savannah',
    '/storage/staff/marcus.jpg',
    '+33 6 23 45 67 89',
    '2017-06-15'
),
(
    'b1000000-0000-0000-0000-000000000003',
    'elena.moreau@savanna-zoo.com',
    'Elena Moreau',
    'zookeeper',
    'aquarium',
    '/storage/staff/elena.jpg',
    '+33 6 34 56 78 90',
    '2018-09-01'
),
(
    'b1000000-0000-0000-0000-000000000004',
    'yuki.tanaka@savanna-zoo.com',
    'Dr. Yuki Tanaka',
    'vet',
    NULL,
    '/storage/staff/yuki.jpg',
    '+33 6 45 67 89 01',
    '2019-01-10'
),
(
    'b1000000-0000-0000-0000-000000000005',
    'lucas.petit@savanna-zoo.com',
    'Lucas Petit',
    'reception',
    NULL,
    '/storage/staff/lucas.jpg',
    '+33 6 56 78 90 12',
    '2021-04-20'
);
