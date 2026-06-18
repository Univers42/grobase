-- ============================================================
-- 001_zoo_tables.sql — Savanna Park Zoo: all tables
--
-- Consolidates everything into PostgreSQL so PostgREST can
-- serve every collection through a single REST endpoint.
-- ============================================================

-- Force public schema (db-bootstrap sets search_path = auth, public)
SET search_path TO public;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Staff ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS staff (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       TEXT UNIQUE NOT NULL,
    full_name   TEXT NOT NULL,
    role        TEXT NOT NULL CHECK (role IN ('admin', 'zookeeper', 'vet', 'reception')),
    zone        TEXT CHECK (zone IN ('savannah', 'arctic', 'rainforest', 'aquarium', 'reptile', 'aviary', 'petting')),
    avatar_url  TEXT,
    phone       TEXT,
    hired_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Animals ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS animals (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                TEXT NOT NULL,
    species             TEXT NOT NULL,
    common_name         TEXT NOT NULL,
    zone                TEXT NOT NULL CHECK (zone IN (
                            'savannah','arctic','rainforest','aquarium',
                            'reptile','aviary','petting')),
    status              TEXT NOT NULL DEFAULT 'active' CHECK (status IN (
                            'active','resting','medical','quarantine','breeding')),
    sex                 TEXT CHECK (sex IN ('male','female')),
    date_of_birth       DATE,
    arrival_date        DATE,
    origin              TEXT,                   -- country or description
    weight_kg           NUMERIC(10,2),
    height_cm           NUMERIC(10,2),
    diet_type           TEXT CHECK (diet_type IN ('carnivore','herbivore','omnivore')),
    conservation_status TEXT CHECK (conservation_status IN ('LC','NT','VU','EN','CR')),
    description         TEXT,
    fun_facts           JSONB DEFAULT '[]'::jsonb,
    feeding_schedule    JSONB DEFAULT '[]'::jsonb,
    photos              JSONB DEFAULT '[]'::jsonb,
    cover_photo         TEXT,
    is_featured         BOOLEAN NOT NULL DEFAULT FALSE,
    total_feedings      INTEGER NOT NULL DEFAULT 0,
    keeper_id           UUID REFERENCES staff(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_animals_zone   ON animals (zone);
CREATE INDEX IF NOT EXISTS idx_animals_status ON animals (status);
CREATE INDEX IF NOT EXISTS idx_animals_keeper ON animals (keeper_id);

-- ── Events ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title           TEXT NOT NULL,
    type            TEXT NOT NULL,
    zone            TEXT,
    host            TEXT,
    start_at        TIMESTAMPTZ NOT NULL,
    end_at          TIMESTAMPTZ,
    capacity        INTEGER,
    registrations   INTEGER NOT NULL DEFAULT 0,
    price_eur       NUMERIC(8,2) NOT NULL DEFAULT 0,
    is_free         BOOLEAN NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    is_full         BOOLEAN NOT NULL DEFAULT FALSE,
    description     TEXT,
    cover_photo     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_active ON events (is_active, start_at);

-- ── Feeding Logs ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS feeding_logs (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    animal_id   UUID REFERENCES animals(id) ON DELETE SET NULL,
    keeper_id   UUID REFERENCES staff(id) ON DELETE SET NULL,
    food_type   TEXT NOT NULL,
    quantity_kg NUMERIC(10,3),
    notes       TEXT,
    fed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_feeding_animal ON feeding_logs (animal_id, fed_at DESC);

-- ── Health Records ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS health_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    animal_id       UUID REFERENCES animals(id) ON DELETE SET NULL,
    vet_id          UUID REFERENCES staff(id) ON DELETE SET NULL,
    record_type     TEXT NOT NULL CHECK (record_type IN (
                        'checkup','vaccination','surgery','dental',
                        'blood_work','injury','observation')),
    diagnosis       TEXT,
    treatment       TEXT,
    weight_kg       NUMERIC(10,2),
    temperature_c   NUMERIC(4,1),
    next_checkup    DATE,
    notes           TEXT,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_health_animal ON health_records (animal_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_vet    ON health_records (vet_id);

-- ── Visitor Messages ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS visitor_messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    visitor_name    TEXT NOT NULL,
    email           TEXT,
    subject         TEXT,
    message         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'unread' CHECK (status IN (
                        'unread','read','replied','archived')),
    reply           TEXT,
    replied_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_status ON visitor_messages (status, created_at DESC);

-- ── Ticket Types ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ticket_types (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT UNIQUE NOT NULL,
    price_eur   NUMERIC(8,2) NOT NULL CHECK (price_eur >= 0),
    description TEXT,
    color       TEXT,
    max_per_day INTEGER DEFAULT 500,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Tickets ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tickets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_type_id  UUID NOT NULL REFERENCES ticket_types(id),
    visitor_name    TEXT NOT NULL,
    visitor_email   TEXT,
    visit_date      DATE NOT NULL,
    quantity        INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    total_eur       NUMERIC(10,2) NOT NULL,
    qr_code         TEXT,
    status          TEXT NOT NULL DEFAULT 'valid'
                        CHECK (status IN ('valid','used','cancelled','refunded')),
    sold_by         UUID REFERENCES staff(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tickets_date   ON tickets (visit_date);
CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets (status);
CREATE INDEX IF NOT EXISTS idx_tickets_type   ON tickets (ticket_type_id);

-- ── Visitor Stats (daily aggregates) ──────────────────────────
CREATE TABLE IF NOT EXISTS visitor_stats (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stat_date       DATE UNIQUE NOT NULL,
    total_visitors  INTEGER NOT NULL DEFAULT 0,
    total_revenue   NUMERIC(12,2) NOT NULL DEFAULT 0,
    tickets_sold    INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Audit Log ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id    UUID REFERENCES staff(id),
    action      TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id   TEXT NOT NULL,
    payload     JSONB DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log (entity_type, entity_id);

-- ── Explicit Grants ───────────────────────────────────────────
-- Ensure anon + authenticated roles can access all zoo tables
DO $$
DECLARE
    _tbl TEXT;
BEGIN
    FOR _tbl IN VALUES
        ('staff'), ('animals'), ('events'), ('feeding_logs'),
        ('health_records'), ('visitor_messages'), ('ticket_types'),
        ('tickets'), ('visitor_stats'), ('audit_log')
    LOOP
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO anon, authenticated', _tbl);
    END LOOP;
END;
$$;
