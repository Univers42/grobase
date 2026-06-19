-- ============================================
-- SCHEMA: Authentication & Authorization
-- ============================================

CREATE TABLE IF NOT EXISTS "Role" (
    "id"          SERIAL PRIMARY KEY,
    "name"        VARCHAR(50) UNIQUE NOT NULL,
    "description" TEXT,
    "created_at"  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS "Permission" (
    "id"       SERIAL PRIMARY KEY,
    "name"     VARCHAR(100) UNIQUE NOT NULL,
    "resource" VARCHAR(50) NOT NULL,
    "action"   VARCHAR(20) NOT NULL
);

CREATE TABLE IF NOT EXISTS "RolePermission" (
    "role_id"       INT NOT NULL REFERENCES "Role"("id") ON DELETE CASCADE,
    "permission_id" INT NOT NULL REFERENCES "Permission"("id") ON DELETE CASCADE,
    PRIMARY KEY ("role_id", "permission_id")
);

CREATE TABLE IF NOT EXISTS "User" (
    "id"                 SERIAL PRIMARY KEY,
    "email"              VARCHAR(255) UNIQUE NOT NULL,
    "password"           VARCHAR(255) NOT NULL,
    "first_name"         VARCHAR(100) NOT NULL,
    "last_name"          VARCHAR(100),
    "phone_number"       VARCHAR(20),
    "city"               VARCHAR(100),
    "country"            VARCHAR(100) DEFAULT 'France',
    "postal_code"        VARCHAR(10),
    "role_id"            INT REFERENCES "Role"("id"),
    "is_active"          BOOLEAN DEFAULT TRUE,
    "is_email_verified"  BOOLEAN DEFAULT FALSE,
    "is_deleted"         BOOLEAN DEFAULT FALSE,
    "deleted_at"         TIMESTAMPTZ,
    "preferred_language" VARCHAR(5) DEFAULT 'fr',
    "gdpr_consent"       BOOLEAN DEFAULT FALSE,
    "gdpr_consent_date"  TIMESTAMPTZ,
    "marketing_consent"  BOOLEAN DEFAULT FALSE,
    "created_at"         TIMESTAMPTZ DEFAULT NOW(),
    "updated_at"         TIMESTAMPTZ DEFAULT NOW(),
    "last_login_at"      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_user_email ON "User"("email");
CREATE INDEX IF NOT EXISTS idx_user_role ON "User"("role_id");

CREATE TABLE IF NOT EXISTS "UserAddress" (
    "id"             SERIAL PRIMARY KEY,
    "user_id"        INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "label"          VARCHAR(50),
    "street_address" TEXT NOT NULL,
    "city"           VARCHAR(100) NOT NULL,
    "postal_code"    VARCHAR(10) NOT NULL,
    "country"        VARCHAR(100) DEFAULT 'France',
    "latitude"       DECIMAL(10,8),
    "longitude"      DECIMAL(11,8),
    "is_default"     BOOLEAN DEFAULT FALSE,
    "created_at"     TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_address_user ON "UserAddress"("user_id");

CREATE TABLE IF NOT EXISTS "PasswordResetToken" (
    "id"         SERIAL PRIMARY KEY,
    "token"      VARCHAR(255) UNIQUE NOT NULL,
    "user_id"    INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "expires_at" TIMESTAMPTZ NOT NULL,
    "used"       BOOLEAN DEFAULT FALSE,
    "created_at" TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_prt_token ON "PasswordResetToken"("token");

CREATE TABLE IF NOT EXISTS "UserSession" (
    "id"            SERIAL PRIMARY KEY,
    "user_id"       INT NOT NULL REFERENCES "User"("id") ON DELETE CASCADE,
    "session_token" VARCHAR(500) UNIQUE NOT NULL,
    "ip_address"    VARCHAR(45),
    "user_agent"    TEXT,
    "created_at"    TIMESTAMPTZ DEFAULT NOW(),
    "expires_at"    TIMESTAMPTZ NOT NULL,
    "is_active"     BOOLEAN DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_session_token ON "UserSession"("session_token");
