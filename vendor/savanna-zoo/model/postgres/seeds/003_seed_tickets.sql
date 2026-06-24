-- ============================================================
-- 003_seed_tickets.sql — 210 ticket records over the last 30 days
--
-- Uses generate_series to produce 7 tickets per day × 30 days.
-- Each day cycles through ticket types and random visitor names.
-- ============================================================

-- Temp table of sample visitor names to cycle through
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
day_series AS (
    SELECT d::date AS visit_date,
           row_number() OVER () - 1 AS day_idx
    FROM generate_series(
        current_date - INTERVAL '29 days',
        current_date,
        '1 day'
    ) AS d
),
tickets_per_day AS (
    SELECT
        d.visit_date,
        n.idx AS slot,
        n.vname,
        n.vemail
    FROM day_series d
    CROSS JOIN names n
),
type_cycle(slot_mod, type_id, qty, unit_price) AS (
    VALUES
        (0, 'a1000000-0000-0000-0000-000000000001'::uuid, 1, 24.90),
        (1, 'a1000000-0000-0000-0000-000000000002'::uuid, 2, 14.90),
        (2, 'a1000000-0000-0000-0000-000000000003'::uuid, 1, 18.90),
        (3, 'a1000000-0000-0000-0000-000000000004'::uuid, 1, 79.90),
        (4, 'a1000000-0000-0000-0000-000000000005'::uuid, 1, 64.90),
        (5, 'a1000000-0000-0000-0000-000000000001'::uuid, 2, 24.90),
        (6, 'a1000000-0000-0000-0000-000000000002'::uuid, 3, 14.90)
)
INSERT INTO tickets (ticket_type_id, visitor_name, visitor_email, visit_date, quantity, total_eur, sold_by, status)
SELECT
    tc.type_id,
    tp.vname,
    tp.vemail,
    tp.visit_date,
    tc.qty,
    tc.qty * tc.unit_price,
    -- Assign sold_by to reception (Lucas) mostly, with some from admin (Sophie)
    CASE WHEN tp.slot < 5
         THEN 'b1000000-0000-0000-0000-000000000005'::uuid
         ELSE 'b1000000-0000-0000-0000-000000000001'::uuid
    END,
    CASE
        WHEN tp.visit_date < current_date THEN 'used'
        WHEN tp.visit_date = current_date THEN 'valid'
        ELSE 'valid'
    END
FROM tickets_per_day tp
JOIN type_cycle tc ON tc.slot_mod = tp.slot;
