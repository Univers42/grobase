-- ============================================================
-- 002_zoo_functions.sql — Triggers & utility functions
-- ============================================================
SET search_path
TO public;

-- ── 1. Generic updated_at trigger ─────────────────────────────
CREATE OR REPLACE FUNCTION zoo_set_updated_at
()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now
();
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    _tbl TEXT;
BEGIN
  FOR _tbl IN VALUES
  ('staff'),
  ('animals'),
  ('events'),
  ('health_records'),
  ('visitor_messages'),
  ('ticket_types'),
  ('tickets'),
  ('visitor_stats')
    LOOP
  EXECUTE format
  (
            'DROP TRIGGER IF EXISTS trg_zoo_updated_at ON %I; '
            'CREATE TRIGGER trg_zoo_updated_at '
            'BEFORE UPDATE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION zoo_set_updated_at()',
            _tbl, _tbl
        );
END
LOOP;
END;
$$;

-- ── 2. Auto QR code on ticket insert ──────────────────────────
CREATE OR REPLACE FUNCTION zoo_generate_ticket_qr
()
RETURNS TRIGGER AS $$
BEGIN
    NEW.qr_code = 'ZOO-' || to_char
(NEW.visit_date, 'YYYYMMDD')
                  || '-' || upper
(substr
(replace
(NEW.id::text, '-', ''), 1, 8));
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_zoo_ticket_qr
ON tickets;
CREATE TRIGGER trg_zoo_ticket_qr
    BEFORE
INSERT ON
tickets
FOR
EACH
ROW
EXECUTE FUNCTION zoo_generate_ticket_qr
();

-- ── 3. Upsert visitor_stats on ticket insert ──────────────────
CREATE OR REPLACE FUNCTION zoo_upsert_visitor_stats
()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO visitor_stats
    (stat_date, total_visitors, total_revenue, tickets_sold)
  VALUES
    (NEW.visit_date, NEW.quantity, NEW.total_eur, 1)
  ON CONFLICT
  (stat_date) DO
  UPDATE SET
        total_visitors = visitor_stats.total_visitors + EXCLUDED.total_visitors,
        total_revenue  = visitor_stats.total_revenue  + EXCLUDED.total_revenue,
        tickets_sold   = visitor_stats.tickets_sold   + EXCLUDED.tickets_sold,
        updated_at     = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_zoo_visitor_stats
ON tickets;
CREATE TRIGGER trg_zoo_visitor_stats
    AFTER
INSERT ON
tickets
FOR
EACH
ROW
EXECUTE FUNCTION zoo_upsert_visitor_stats
();
