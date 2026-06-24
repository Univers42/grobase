-- ============================================================
-- 01_schema.sql — Surfind Spain: schema + RLS on Grobase (PostgreSQL)
--
-- Re-platforms the Laravel/MySQL surf-beach directory onto the shared
-- Grobase public schema so PostgREST serves every table through one
-- REST endpoint. Idempotent: CREATE TABLE IF NOT EXISTS + CREATE OR
-- REPLACE + DROP POLICY IF EXISTS, so re-running converges.
--
-- SECURITY (the #1 rule): the staff role is read from app_metadata
-- (server-controlled via the GoTrue admin API), NEVER user_metadata —
-- which is fully client-controlled at self-signup. Trusting user_metadata
-- would let any visitor POST {"data":{"role":"admin"}} and gain admin.
-- GoTrue owns users now: user_id/created_by are uuid = the JWT sub, with
-- NO FK to a local users table.
-- ============================================================

-- Force public schema (db-bootstrap sets search_path = auth, public)
SET search_path TO public;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Identity helpers ──────────────────────────────────────────
-- surf_uid(): the caller's GoTrue user id (JWT sub) as uuid, or NULL for anon.
CREATE OR REPLACE FUNCTION public.surf_uid() RETURNS uuid AS $$
  SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$ LANGUAGE SQL STABLE;

-- surf_jwt_role(): the trusted staff role, read ONLY from app_metadata.
CREATE OR REPLACE FUNCTION public.surf_jwt_role() RETURNS text AS $$
  SELECT current_setting('request.jwt.claims', true)::jsonb
    -> 'app_metadata' ->> 'role';
$$ LANGUAGE SQL STABLE;

-- ── Locations (provinces) ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS locations (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT UNIQUE NOT NULL,
    slug        TEXT UNIQUE NOT NULL
);

-- ── Amenities ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS amenities (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    icon        TEXT
);

-- ── Beaches ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS beaches (
    id                BIGSERIAL PRIMARY KEY,
    name              TEXT NOT NULL,
    slug              TEXT UNIQUE NOT NULL,
    location_id       BIGINT REFERENCES locations(id),
    created_by        UUID,
    short_description TEXT,
    description       TEXT,
    difficulty        TEXT CHECK (difficulty IN ('beginner', 'intermediate', 'advanced')),
    status            TEXT NOT NULL DEFAULT 'published'
                          CHECK (status IN ('draft', 'published', 'archived')),
    published_at      TIMESTAMPTZ,
    latitude          NUMERIC(10,7),
    longitude         NUMERIC(10,7),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_beaches_location ON beaches (location_id);
CREATE INDEX IF NOT EXISTS idx_beaches_status   ON beaches (status);

-- ── Beach images ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS beach_images (
    id            BIGSERIAL PRIMARY KEY,
    beach_id      BIGINT NOT NULL REFERENCES beaches(id) ON DELETE CASCADE,
    user_id       UUID,
    source_type   TEXT CHECK (source_type IN ('upload', 'url')),
    path          TEXT,
    external_url  TEXT,
    is_cover      BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order    SMALLINT NOT NULL DEFAULT 0,
    alt_text      TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_beach_images_beach ON beach_images (beach_id);

-- ── Amenity ↔ Beach (pivot) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS amenity_beach (
    beach_id    BIGINT NOT NULL REFERENCES beaches(id) ON DELETE CASCADE,
    amenity_id  BIGINT NOT NULL REFERENCES amenities(id) ON DELETE CASCADE,
    PRIMARY KEY (beach_id, amenity_id)
);

CREATE INDEX IF NOT EXISTS idx_amenity_beach_amenity ON amenity_beach (amenity_id);

-- ── Comments ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS comments (
    id          BIGSERIAL PRIMARY KEY,
    user_id     UUID DEFAULT public.surf_uid(),
    beach_id    BIGINT NOT NULL REFERENCES beaches(id) ON DELETE CASCADE,
    content     TEXT,
    published   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comments_beach ON comments (beach_id);

-- ── Favorites ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS favorites (
    user_id     UUID DEFAULT public.surf_uid(),
    beach_id    BIGINT NOT NULL REFERENCES beaches(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, beach_id)
);

CREATE INDEX IF NOT EXISTS idx_favorites_beach ON favorites (beach_id);

-- ── updated_at trigger on beaches ─────────────────────────────
CREATE OR REPLACE FUNCTION public.surf_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_surf_beaches_updated_at ON beaches;
CREATE TRIGGER trg_surf_beaches_updated_at
    BEFORE UPDATE ON beaches
    FOR EACH ROW EXECUTE FUNCTION public.surf_set_updated_at();

-- ── Grants ────────────────────────────────────────────────────
DO $$
DECLARE
    _tbl TEXT;
BEGIN
    FOR _tbl IN VALUES
        ('locations'), ('amenities'), ('beaches'), ('beach_images'),
        ('amenity_beach'), ('comments'), ('favorites')
    LOOP
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO anon, authenticated', _tbl);
    END LOOP;
END;
$$;

-- bigserial inserts (comments) need USAGE on the id sequence for the role doing
-- the INSERT — without this an authenticated user's comment fails with
-- "permission denied for sequence comments_id_seq".
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;

-- ── Row Level Security ────────────────────────────────────────
ALTER TABLE locations     ENABLE ROW LEVEL SECURITY;
ALTER TABLE amenities     ENABLE ROW LEVEL SECURITY;
ALTER TABLE beaches       ENABLE ROW LEVEL SECURITY;
ALTER TABLE beach_images  ENABLE ROW LEVEL SECURITY;
ALTER TABLE amenity_beach ENABLE ROW LEVEL SECURITY;
ALTER TABLE comments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE favorites     ENABLE ROW LEVEL SECURITY;

-- Public catalog: anyone may read.
DROP POLICY IF EXISTS locations_read ON locations;
CREATE POLICY locations_read ON locations FOR SELECT USING (true);

DROP POLICY IF EXISTS amenities_read ON amenities;
CREATE POLICY amenities_read ON amenities FOR SELECT USING (true);

DROP POLICY IF EXISTS beach_images_read ON beach_images;
CREATE POLICY beach_images_read ON beach_images FOR SELECT USING (true);

DROP POLICY IF EXISTS amenity_beach_read ON amenity_beach;
CREATE POLICY amenity_beach_read ON amenity_beach FOR SELECT USING (true);

-- Beaches: published visible to all; admin sees every status and may write.
DROP POLICY IF EXISTS beaches_read ON beaches;
CREATE POLICY beaches_read ON beaches FOR SELECT
  USING (status = 'published' OR public.surf_jwt_role() = 'admin');

DROP POLICY IF EXISTS beaches_insert ON beaches;
CREATE POLICY beaches_insert ON beaches FOR INSERT
  TO authenticated
  WITH CHECK (public.surf_jwt_role() = 'admin');

DROP POLICY IF EXISTS beaches_update ON beaches;
CREATE POLICY beaches_update ON beaches FOR UPDATE
  TO authenticated
  USING (public.surf_jwt_role() = 'admin')
  WITH CHECK (public.surf_jwt_role() = 'admin');

DROP POLICY IF EXISTS beaches_delete ON beaches;
CREATE POLICY beaches_delete ON beaches FOR DELETE
  TO authenticated
  USING (public.surf_jwt_role() = 'admin');

-- Comments: published readable by all; authors/admin see+edit their own.
DROP POLICY IF EXISTS comments_read ON comments;
CREATE POLICY comments_read ON comments FOR SELECT
  USING (published OR user_id = public.surf_uid() OR public.surf_jwt_role() = 'admin');

DROP POLICY IF EXISTS comments_insert ON comments;
CREATE POLICY comments_insert ON comments FOR INSERT
  TO authenticated
  WITH CHECK (user_id = public.surf_uid());

DROP POLICY IF EXISTS comments_update ON comments;
CREATE POLICY comments_update ON comments FOR UPDATE
  TO authenticated
  USING (user_id = public.surf_uid() OR public.surf_jwt_role() = 'admin')
  WITH CHECK (user_id = public.surf_uid() OR public.surf_jwt_role() = 'admin');

DROP POLICY IF EXISTS comments_delete ON comments;
CREATE POLICY comments_delete ON comments FOR DELETE
  TO authenticated
  USING (user_id = public.surf_uid() OR public.surf_jwt_role() = 'admin');

-- Favorites: strictly owner-scoped (private table).
DROP POLICY IF EXISTS favorites_all ON favorites;
CREATE POLICY favorites_all ON favorites FOR ALL
  TO authenticated
  USING (user_id = public.surf_uid())
  WITH CHECK (user_id = public.surf_uid());
