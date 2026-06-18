-- ============================================
-- COMPANY & ORGANIZATION SCHEMA (5NF)
-- ============================================
-- Covers: WorkingHours, Company, CompanyOwner (M:N), Event
-- Subject: "Les horaires doivent être visible sur le pied de page"
-- ============================================

-- ─────────────────────────────────────────────
-- Working Hours (per day, reusable by companies)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "WorkingHours" (
    "id"      SERIAL PRIMARY KEY,
    "day"     VARCHAR(15) NOT NULL UNIQUE,
    "opening" VARCHAR(5) NOT NULL,
    "closing" VARCHAR(5) NOT NULL
);

COMMENT ON TABLE  "WorkingHours"       IS 'Opening hours displayed in the website footer (Mon–Sun).';
COMMENT ON COLUMN "WorkingHours"."day" IS 'French day names as required by the subject.';

-- ─────────────────────────────────────────────
-- Companies (the catering businesses)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "Company" (
    "id"                 SERIAL PRIMARY KEY,
    "name"               VARCHAR(255) NOT NULL,
    "slogan"             VARCHAR(255),
    "description"        TEXT,
    "first_opening_date" DATE NOT NULL,
    "address"            TEXT NOT NULL,
    "city"               VARCHAR(100) NOT NULL,
    "postal_code"        VARCHAR(10) NOT NULL,
    "country"            VARCHAR(100) DEFAULT 'France',
    "phone"              VARCHAR(20) NOT NULL,
    "email"              VARCHAR(255) NOT NULL,
    "website"            VARCHAR(255),
    "siret"              VARCHAR(14) UNIQUE,
    "logo_url"           VARCHAR(255),
    "is_active"          BOOLEAN DEFAULT TRUE,
    "created_at"         TIMESTAMPTZ DEFAULT NOW(),
    "updated_at"         TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_company_active ON "Company"("is_active");

COMMENT ON TABLE "Company" IS 'Catering companies. Supports multi-company expansion.';

-- ─────────────────────────────────────────────
-- Company ↔ User M:N junction (Owners)
-- A company can have multiple owners
-- A user can own multiple companies
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "CompanyOwner" (
    "company_id"  INT NOT NULL REFERENCES "Company"("id") ON DELETE CASCADE,
    "user_id"     INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "role"        VARCHAR(50) DEFAULT 'owner',  -- owner, co-owner, manager
    "joined_at"   TIMESTAMPTZ DEFAULT NOW(),
    "is_primary"  BOOLEAN DEFAULT FALSE,        -- primary contact
    PRIMARY KEY ("company_id", "user_id")
);

CREATE INDEX IF NOT EXISTS idx_company_owner_user ON "CompanyOwner"("user_id");

COMMENT ON TABLE "CompanyOwner" IS 'M:N junction — owners/managers of companies.';

-- ─────────────────────────────────────────────
-- Company ↔ WorkingHours M:N junction
-- Different companies can have different hours
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "CompanyWorkingHours" (
    "company_id"       INT NOT NULL REFERENCES "Company"("id") ON DELETE CASCADE,
    "working_hours_id" INT NOT NULL REFERENCES "WorkingHours"("id") ON DELETE CASCADE,
    PRIMARY KEY ("company_id", "working_hours_id")
);

COMMENT ON TABLE "CompanyWorkingHours" IS 'Links companies to their working hours.';

-- ─────────────────────────────────────────────
-- Events (catering events realized by company)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "Event" (
    "id"          SERIAL PRIMARY KEY,
    "company_id"  INT NOT NULL REFERENCES "Company"("id") ON DELETE CASCADE,
    "name"        VARCHAR(255) NOT NULL,
    "description" TEXT,
    "event_type"  VARCHAR(50),                 -- wedding, corporate, birthday, etc.
    "guest_count" INT,
    "event_date"  DATE NOT NULL,
    "location"    VARCHAR(255),
    "is_public"   BOOLEAN DEFAULT TRUE,        -- show in portfolio
    "created_at"  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_event_company ON "Event"("company_id");
CREATE INDEX IF NOT EXISTS idx_event_date ON "Event"("event_date" DESC);

COMMENT ON TABLE "Event" IS 'Catering events realized — for portfolio & stats.';
