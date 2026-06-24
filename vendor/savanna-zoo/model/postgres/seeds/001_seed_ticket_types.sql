-- ============================================================
-- 001_seed_ticket_types.sql — 5 ticket categories
-- ============================================================

INSERT INTO ticket_types (id, name, price_eur, description, color, max_per_day) VALUES
('a1000000-0000-0000-0000-000000000001', 'Adult',   24.90, 'Standard adult entry (13+)',         '#1a3a2a', 500),
('a1000000-0000-0000-0000-000000000002', 'Child',   14.90, 'Children aged 3-12. Under 3 free.',  '#4a9e6f', 300),
('a1000000-0000-0000-0000-000000000003', 'Senior',  18.90, 'Visitors aged 65+',                  '#8b7355', 200),
('a1000000-0000-0000-0000-000000000004', 'VIP',     79.90, 'Skip-the-line + behind-the-scenes',  '#c4702a', 30),
('a1000000-0000-0000-0000-000000000005', 'Family',  64.90, '2 adults + up to 3 children',        '#2c6e49', 150);
