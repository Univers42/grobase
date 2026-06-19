-- ============================================================
-- 03_deep_schema.sql — Surfind Spain DEEP expansion (PostgreSQL)
--
-- Adds the surf-TRACKING layer on top of 01_schema.sql:
--   • beaches surf-intel columns (break/tide/season/rating aggregates/media)
--   • articles (the /blog) — admin-write, public-read
--   • surf_reports — public live feed, owner-writable (realtime kept ON)
--   • beach_ratings — owner-scoped, a SECURITY DEFINER trigger recomputes
--     beaches.rating_avg/rating_count (its realtime broadcast is dropped)
--   • surfer_profiles — public read (the /ranking), owner write
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + CREATE TABLE IF NOT EXISTS +
-- CREATE OR REPLACE + DROP POLICY IF EXISTS, so re-running converges.
--
-- SECURITY: role from app_metadata (surf_jwt_role), NEVER user_metadata.
-- ============================================================
SET search_path TO public;

-- ── 1) beaches surf-intel + media + rating aggregates ─────────
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS break_type     TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS wave_direction TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS best_tide      TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS best_season    TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS bottom_type    TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS wave_quality   INT CHECK (wave_quality BETWEEN 1 AND 5);
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS crowd_level    TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS water_temp_c   TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS hazards        TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS video_url      TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS cover_image    TEXT;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS rating_avg     NUMERIC(3,2) DEFAULT 0;
ALTER TABLE beaches ADD COLUMN IF NOT EXISTS rating_count   INT DEFAULT 0;

-- ── 2) articles (blog) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS articles (
    id            BIGSERIAL PRIMARY KEY,
    slug          TEXT UNIQUE NOT NULL,
    title         TEXT NOT NULL,
    excerpt       TEXT,
    body          TEXT,                       -- markdown
    cover_image   TEXT,
    author_name   TEXT,
    beach_id      BIGINT REFERENCES beaches(id) ON DELETE SET NULL,
    tags          TEXT[],
    read_minutes  INT,
    published     BOOLEAN NOT NULL DEFAULT TRUE,
    published_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_articles_published ON articles (published, published_at DESC);

-- ── 3) surf_reports (public live feed) ────────────────────────
CREATE TABLE IF NOT EXISTS surf_reports (
    id            BIGSERIAL PRIMARY KEY,
    beach_id      BIGINT NOT NULL REFERENCES beaches(id) ON DELETE CASCADE,
    user_id       UUID DEFAULT public.surf_uid(),
    author_name   TEXT,
    wave_height_m NUMERIC(4,1),
    period_s      INT,
    wind          TEXT,
    crowd         TEXT,
    quality       INT CHECK (quality BETWEEN 1 AND 5),
    comment       TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_surf_reports_beach   ON surf_reports (beach_id);
CREATE INDEX IF NOT EXISTS idx_surf_reports_created ON surf_reports (created_at DESC);

-- ── 4) beach_ratings (owner-scoped) + aggregate trigger ───────
CREATE TABLE IF NOT EXISTS beach_ratings (
    user_id     UUID DEFAULT public.surf_uid(),
    beach_id    BIGINT NOT NULL REFERENCES beaches(id) ON DELETE CASCADE,
    stars       INT CHECK (stars BETWEEN 1 AND 5),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, beach_id)
);

-- Recompute the public rating aggregate for one beach. SECURITY DEFINER so the
-- aggregate over ALL raters is visible to a single owner-scoped writer.
CREATE OR REPLACE FUNCTION public.surf_recompute_rating() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    _beach BIGINT := COALESCE(NEW.beach_id, OLD.beach_id);
BEGIN
    UPDATE beaches b SET
        rating_avg   = COALESCE((SELECT round(avg(stars)::numeric, 2) FROM beach_ratings WHERE beach_id = _beach), 0),
        rating_count = (SELECT count(*) FROM beach_ratings WHERE beach_id = _beach)
    WHERE b.id = _beach;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_surf_recompute_rating ON beach_ratings;
CREATE TRIGGER trg_surf_recompute_rating
    AFTER INSERT OR UPDATE OR DELETE ON beach_ratings
    FOR EACH ROW EXECUTE FUNCTION public.surf_recompute_rating();

-- ── 5) surfer_profiles (public read for the ranking) ──────────
CREATE TABLE IF NOT EXISTS surfer_profiles (
    user_id       UUID PRIMARY KEY DEFAULT public.surf_uid(),
    display_name  TEXT,
    level         TEXT CHECK (level IN ('principiante', 'intermedio', 'avanzado', 'pro')),
    home_break_id BIGINT REFERENCES beaches(id) ON DELETE SET NULL,
    board_quiver  TEXT,
    bio           TEXT,
    avatar_url    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_surf_profiles_updated_at ON surfer_profiles;
CREATE TRIGGER trg_surf_profiles_updated_at
    BEFORE UPDATE ON surfer_profiles
    FOR EACH ROW EXECUTE FUNCTION public.surf_set_updated_at();

-- ── 6) Grants ─────────────────────────────────────────────────
DO $$
DECLARE _tbl TEXT;
BEGIN
    FOR _tbl IN VALUES ('articles'), ('surf_reports'), ('beach_ratings'), ('surfer_profiles')
    LOOP
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO anon, authenticated', _tbl);
    END LOOP;
END;
$$;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;

-- ── 7) Row Level Security ─────────────────────────────────────
ALTER TABLE articles        ENABLE ROW LEVEL SECURITY;
ALTER TABLE surf_reports    ENABLE ROW LEVEL SECURITY;
ALTER TABLE beach_ratings   ENABLE ROW LEVEL SECURITY;
ALTER TABLE surfer_profiles ENABLE ROW LEVEL SECURITY;

-- articles: published readable by all; admin writes.
DROP POLICY IF EXISTS articles_read ON articles;
CREATE POLICY articles_read ON articles FOR SELECT
  USING (published OR public.surf_jwt_role() = 'admin');
DROP POLICY IF EXISTS articles_insert ON articles;
CREATE POLICY articles_insert ON articles FOR INSERT
  TO authenticated WITH CHECK (public.surf_jwt_role() = 'admin');
DROP POLICY IF EXISTS articles_update ON articles;
CREATE POLICY articles_update ON articles FOR UPDATE
  TO authenticated USING (public.surf_jwt_role() = 'admin') WITH CHECK (public.surf_jwt_role() = 'admin');
DROP POLICY IF EXISTS articles_delete ON articles;
CREATE POLICY articles_delete ON articles FOR DELETE
  TO authenticated USING (public.surf_jwt_role() = 'admin');

-- surf_reports: public live feed (anyone reads); authors write their own.
DROP POLICY IF EXISTS surf_reports_read ON surf_reports;
CREATE POLICY surf_reports_read ON surf_reports FOR SELECT USING (true);
DROP POLICY IF EXISTS surf_reports_insert ON surf_reports;
CREATE POLICY surf_reports_insert ON surf_reports FOR INSERT
  TO authenticated WITH CHECK (user_id = public.surf_uid());
DROP POLICY IF EXISTS surf_reports_update ON surf_reports;
CREATE POLICY surf_reports_update ON surf_reports FOR UPDATE
  TO authenticated USING (user_id = public.surf_uid() OR public.surf_jwt_role() = 'admin')
  WITH CHECK (user_id = public.surf_uid() OR public.surf_jwt_role() = 'admin');
DROP POLICY IF EXISTS surf_reports_delete ON surf_reports;
CREATE POLICY surf_reports_delete ON surf_reports FOR DELETE
  TO authenticated USING (user_id = public.surf_uid() OR public.surf_jwt_role() = 'admin');

-- beach_ratings: strictly owner-scoped (the aggregate is the public surface).
DROP POLICY IF EXISTS beach_ratings_all ON beach_ratings;
CREATE POLICY beach_ratings_all ON beach_ratings FOR ALL
  TO authenticated USING (user_id = public.surf_uid()) WITH CHECK (user_id = public.surf_uid());

-- surfer_profiles: public read (ranking); owner writes their own.
DROP POLICY IF EXISTS surfer_profiles_read ON surfer_profiles;
CREATE POLICY surfer_profiles_read ON surfer_profiles FOR SELECT USING (true);
DROP POLICY IF EXISTS surfer_profiles_insert ON surfer_profiles;
CREATE POLICY surfer_profiles_insert ON surfer_profiles FOR INSERT
  TO authenticated WITH CHECK (user_id = public.surf_uid());
DROP POLICY IF EXISTS surfer_profiles_update ON surfer_profiles;
CREATE POLICY surfer_profiles_update ON surfer_profiles FOR UPDATE
  TO authenticated USING (user_id = public.surf_uid()) WITH CHECK (user_id = public.surf_uid());
