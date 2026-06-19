-- ============================================
-- SCHEMA: Messaging & Support
-- ============================================

CREATE TABLE IF NOT EXISTS "Message" (
    "id"           SERIAL PRIMARY KEY,
    "sender_id"    INT REFERENCES "User"("id") ON DELETE SET NULL,
    "recipient_id" INT REFERENCES "User"("id") ON DELETE SET NULL,
    "subject"      VARCHAR(255),
    "body"         TEXT NOT NULL,
    "priority"     VARCHAR(20) DEFAULT 'normal',
    "is_read"      BOOLEAN DEFAULT FALSE,
    "sent_at"      TIMESTAMPTZ DEFAULT NOW(),
    "read_at"      TIMESTAMPTZ,
    "parent_id"    INT REFERENCES "Message"("id")
);

CREATE TABLE IF NOT EXISTS "Notification" (
    "id"         SERIAL PRIMARY KEY,
    "user_id"    INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "type"       VARCHAR(50) NOT NULL,
    "title"      VARCHAR(255),
    "body"       TEXT,
    "link_url"   VARCHAR(500),
    "is_read"    BOOLEAN DEFAULT FALSE,
    "created_at" TIMESTAMPTZ DEFAULT NOW(),
    "read_at"    TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS "SupportTicket" (
    "id"            SERIAL PRIMARY KEY,
    "ticket_number" VARCHAR(50) UNIQUE NOT NULL,
    "created_by"    INT REFERENCES "User"("id") ON DELETE SET NULL,
    "assigned_to"   INT REFERENCES "User"("id") ON DELETE SET NULL,
    "category"      VARCHAR(50) NOT NULL,
    "priority"      VARCHAR(20) DEFAULT 'normal',
    "status"        VARCHAR(20) DEFAULT 'open',
    "subject"       VARCHAR(255) NOT NULL,
    "description"   TEXT,
    "created_at"    TIMESTAMPTZ DEFAULT NOW(),
    "resolved_at"   TIMESTAMPTZ,
    "closed_at"     TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS "TicketMessage" (
    "id"          SERIAL PRIMARY KEY,
    "ticket_id"   INT NOT NULL REFERENCES "SupportTicket"("id") ON DELETE CASCADE,
    "user_id"     INT REFERENCES "User"("id") ON DELETE SET NULL,
    "body"        TEXT NOT NULL,
    "is_internal" BOOLEAN DEFAULT FALSE,
    "created_at"  TIMESTAMPTZ DEFAULT NOW()
);
