-- ============================================================
-- 002_functions_and_triggers.sql — Automated behaviour
-- ============================================================

-- ── 1. Generic updated_at trigger ─────────────────────────────
CREATE OR REPLACE FUNCTION trg_set_updated_at
()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now
();
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to every table with an updated_at column
DO $$
DECLARE
    _tbl TEXT;
BEGIN
  FOR _tbl IN
  SELECT table_name
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND column_name  = 'updated_at'
  LOOP
  EXECUTE format
  (
            'CREATE TRIGGER set_updated_at
             BEFORE UPDATE ON %I
             FOR EACH ROW
             EXECUTE FUNCTION trg_set_updated_at();',
            _tbl
        );
END
LOOP;
END;
$$;

-- ── 2. Auto-generate QR code on ticket insert ─────────────────
CREATE OR REPLACE FUNCTION trg_generate_ticket_qr
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

CREATE TRIGGER generate_ticket_qr
    BEFORE
INSERT ON
tickets
FOR
EACH
ROW
EXECUTE FUNCTION trg_generate_ticket_qr
();

-- ── 3. Upsert visitor_stats when a ticket is inserted ─────────
CREATE OR REPLACE FUNCTION trg_upsert_visitor_stats
()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO visitor_stats
    (stat_date, total_visitors, total_revenue, tickets_sold)
  VALUES
    (NEW.visit_date, NEW.quantity, NEW.total_eur, 1)
  ON CONFLICT
  (stat_date)
    DO
  UPDATE SET
        total_visitors = visitor_stats.total_visitors + EXCLUDED.total_visitors,
        total_revenue  = visitor_stats.total_revenue  + EXCLUDED.total_revenue,
        tickets_sold   = visitor_stats.tickets_sold   + EXCLUDED.tickets_sold,
        updated_at     = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER upsert_visitor_stats
    AFTER
INSERT ON
tickets
FOR
EACH
ROW
EXECUTE FUNCTION trg_upsert_visitor_stats
();

-- ── 4. Audit log helper function (callable via RPC) ───────────
CREATE OR REPLACE FUNCTION log_audit
(
    p_actor_id    UUID,
    p_action      TEXT,
    p_entity_type TEXT,
    p_entity_id   TEXT,
    p_payload     JSONB DEFAULT '{}'::jsonb,
    p_ip          INET  DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_id UUID;
BEGIN
  INSERT INTO audit_log
    (actor_id, action, entity_type, entity_id, payload, ip_address)
  VALUES
    (p_actor_id, p_action, p_entity_type, p_entity_id, p_payload, p_ip)
  RETURNING id INTO v_id;
RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- ── 5. Row-Level Security policies ────────────────────────────
-- NOTE: RLS is prepared but not enforced by default.
--       The BaaS runtime enables it per-request using set_config().

-- Staff: only admins can INSERT/UPDATE/DELETE
ALTER TABLE staff ENABLE ROW LEVEL SECURITY;

CREATE POLICY staff_read  ON staff FOR
SELECT USING (TRUE);
CREATE POLICY staff_write ON staff FOR ALL
    USING
(current_setting
('baas.role', TRUE) = 'admin');

-- Tickets: reception + admin can write; others read-only
ALTER TABLE tickets ENABLE ROW LEVEL SECURITY;

CREATE POLICY tickets_read  ON tickets FOR
SELECT USING (TRUE);
CREATE POLICY tickets_write ON tickets FOR ALL
    USING
(current_setting
('baas.role', TRUE) IN
('admin', 'reception'));

-- Health records: vets + admin can write
ALTER TABLE health_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY health_read  ON health_records FOR
SELECT USING (TRUE);
CREATE POLICY health_write ON health_records FOR ALL
    USING
(current_setting
('baas.role', TRUE) IN
('admin', 'vet'));

-- Audit log: insert-only for all roles, read for admin
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY audit_insert ON audit_log FOR
INSERT WITH CHECK
  (TRUE)
;
CREATE POLICY audit_read   ON audit_log FOR
SELECT
  USING (current_setting('baas.role', TRUE) = 'admin');
