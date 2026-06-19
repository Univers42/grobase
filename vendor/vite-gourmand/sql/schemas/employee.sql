-- ============================================
-- SCHEMA: Employee management
-- ============================================

CREATE TABLE IF NOT EXISTS "TimeOffRequest" (
    "id"           SERIAL PRIMARY KEY,
    "user_id"      INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "start_date"   DATE NOT NULL,
    "end_date"     DATE NOT NULL,
    "type"         VARCHAR(20) NOT NULL,
    "status"       VARCHAR(20) DEFAULT 'pending',
    "reason"       TEXT,
    "decided_by"   INT REFERENCES "User"("id"),
    "requested_at" TIMESTAMPTZ DEFAULT NOW(),
    "decided_at"   TIMESTAMPTZ
);
