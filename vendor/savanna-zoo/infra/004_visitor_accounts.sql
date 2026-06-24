-- ============================================================
-- 004_visitor_accounts.sql — per-user ticket ownership
--
-- Turns the public Tickets flow from anonymous into per-visitor:
-- every visitor signs up in GoTrue (role=visitor) and books tickets
-- that belong to THEM. A visitor sees only their own tickets; staff
-- (admin/reception) see all.
--
-- Why this file exists: the old `tickets_read` policy was
-- `TO authenticated USING (role IN admin,reception)`, so an anon
-- INSERT with `Prefer: return=representation` (PostgREST default)
-- failed the read-back with 42501 — the "Booking failed: new row
-- violates row-level security policy" the user hit. Owner-scoping
-- the row to the booker fixes the read-back AND makes tickets private.
--
-- The two ticket triggers are also promoted to SECURITY DEFINER so the
-- AFTER-INSERT aggregate into visitor_stats (admin-only under RLS)
-- succeeds no matter which role books.
-- ============================================================
SET search_path TO public;

-- ── GoTrue user id (sub) from the request JWT — NULL for anon ──
-- SECURITY DEFINER functions below pin search_path; this STABLE
-- reader does not write, so it stays INVOKER.
CREATE OR REPLACE FUNCTION public.zoo_uid() RETURNS uuid AS $$
  SELECT nullif(
    current_setting('request.jwt.claims', true)::jsonb ->> 'sub', ''
  )::uuid;
$$ LANGUAGE SQL STABLE;

-- ── tickets gain an owner (the booking visitor) ───────────────
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS user_id uuid;
ALTER TABLE tickets ALTER COLUMN user_id SET DEFAULT public.zoo_uid();
CREATE INDEX IF NOT EXISTS idx_tickets_user ON tickets (user_id);

-- ── QR trigger: also stamp the owner when the booker omits it ──
CREATE OR REPLACE FUNCTION zoo_generate_ticket_qr()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        NEW.user_id := public.zoo_uid();
    END IF;
    NEW.qr_code := 'ZOO-' || to_char(NEW.visit_date, 'YYYYMMDD')
                   || '-' || upper(substr(replace(NEW.id::text, '-', ''), 1, 8));
    RETURN NEW;
END;
$$;

-- ── visitor_stats aggregate: SECURITY DEFINER bypasses the ────
--    admin-only RLS on visitor_stats for any booking role.
CREATE OR REPLACE FUNCTION zoo_upsert_visitor_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
    INSERT INTO public.visitor_stats
        (stat_date, total_visitors, total_revenue, tickets_sold)
    VALUES
        (NEW.visit_date, NEW.quantity, NEW.total_eur, 1)
    ON CONFLICT (stat_date) DO UPDATE SET
        total_visitors = visitor_stats.total_visitors + EXCLUDED.total_visitors,
        total_revenue  = visitor_stats.total_revenue  + EXCLUDED.total_revenue,
        tickets_sold   = visitor_stats.tickets_sold   + EXCLUDED.tickets_sold,
        updated_at     = now();
    RETURN NEW;
END;
$$;

-- ── Owner-scoped RLS on tickets ───────────────────────────────
-- INSERT: a visitor may only book under their own id; staff bypass.
-- SELECT: a visitor reads only their tickets; staff read all.
-- UPDATE: same (a visitor can cancel their own).
ALTER TABLE tickets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tickets_insert ON tickets;
DROP POLICY IF EXISTS tickets_read   ON tickets;
DROP POLICY IF EXISTS tickets_write  ON tickets;
DROP POLICY IF EXISTS tickets_update ON tickets;

CREATE POLICY tickets_insert ON tickets FOR INSERT
  TO authenticated
  WITH CHECK (user_id = public.zoo_uid()
              OR zoo_jwt_role() IN ('admin', 'reception'));

CREATE POLICY tickets_read ON tickets FOR SELECT
  TO authenticated
  USING (user_id = public.zoo_uid()
         OR zoo_jwt_role() IN ('admin', 'reception'));

CREATE POLICY tickets_update ON tickets FOR UPDATE
  TO authenticated
  USING (user_id = public.zoo_uid()
         OR zoo_jwt_role() IN ('admin', 'reception'))
  WITH CHECK (user_id = public.zoo_uid()
              OR zoo_jwt_role() IN ('admin', 'reception'));
