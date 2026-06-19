-- ============================================
-- SECURITY: Row Level Security (RLS) + Function search_path
-- ============================================
-- Fixes Supabase health check critical issues:
--   1. RLS not enabled on public tables
--   2. Functions with mutable search_path
--
-- Strategy:
--   • Enable RLS on every table (including Prisma implicit junctions)
--   • Allow full access to `postgres` role (used by Prisma/NestJS)
--   • Allow full access to `service_role` (Supabase admin)
--   • Block `anon` and `authenticated` Supabase roles (our NestJS
--     backend handles auth via JWT, not PostgREST)
-- ============================================


-- ═══════════════════════════════════════════════
-- 1. Enable RLS on ALL tables
-- ═══════════════════════════════════════════════

-- Auth & RBAC
ALTER TABLE "Role"              ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Permission"        ENABLE ROW LEVEL SECURITY;
ALTER TABLE "RolePermission"    ENABLE ROW LEVEL SECURITY;
ALTER TABLE "User"              ENABLE ROW LEVEL SECURITY;
ALTER TABLE "UserAddress"       ENABLE ROW LEVEL SECURITY;
ALTER TABLE "PasswordResetToken" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "UserSession"       ENABLE ROW LEVEL SECURITY;
ALTER TABLE "UserConsent"       ENABLE ROW LEVEL SECURITY;

-- Organization
ALTER TABLE "WorkingHours"          ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Company"               ENABLE ROW LEVEL SECURITY;
ALTER TABLE "CompanyOwner"          ENABLE ROW LEVEL SECURITY;
ALTER TABLE "CompanyWorkingHours"   ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Event"                 ENABLE ROW LEVEL SECURITY;

-- Menu management
ALTER TABLE "Diet"              ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Theme"             ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Menu"              ENABLE ROW LEVEL SECURITY;
ALTER TABLE "MenuImage"         ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Dish"              ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Allergen"          ENABLE ROW LEVEL SECURITY;
ALTER TABLE "DishAllergen"      ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Ingredient"        ENABLE ROW LEVEL SECURITY;
ALTER TABLE "DishIngredient"    ENABLE ROW LEVEL SECURITY;
ALTER TABLE "MenuIngredient"    ENABLE ROW LEVEL SECURITY;

-- Prisma implicit M:N junction tables
ALTER TABLE "_MenuDishes"       ENABLE ROW LEVEL SECURITY;
ALTER TABLE "_DishAllergens"    ENABLE ROW LEVEL SECURITY;

-- Orders
ALTER TABLE "Order"             ENABLE ROW LEVEL SECURITY;
ALTER TABLE "OrderMenu"         ENABLE ROW LEVEL SECURITY;
ALTER TABLE "OrderStatusHistory" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "OrderTag"          ENABLE ROW LEVEL SECURITY;
ALTER TABLE "OrderOrderTag"     ENABLE ROW LEVEL SECURITY;
ALTER TABLE "DeliveryAssignment" ENABLE ROW LEVEL SECURITY;

-- Loyalty & Discounts
ALTER TABLE "Discount"          ENABLE ROW LEVEL SECURITY;
ALTER TABLE "LoyaltyAccount"    ENABLE ROW LEVEL SECURITY;
ALTER TABLE "LoyaltyTransaction" ENABLE ROW LEVEL SECURITY;

-- Promotions
ALTER TABLE "Promotion"         ENABLE ROW LEVEL SECURITY;
ALTER TABLE "UserPromotion"     ENABLE ROW LEVEL SECURITY;

-- Messaging & Support
ALTER TABLE "Message"           ENABLE ROW LEVEL SECURITY;
ALTER TABLE "Notification"      ENABLE ROW LEVEL SECURITY;
ALTER TABLE "SupportTicket"     ENABLE ROW LEVEL SECURITY;
ALTER TABLE "TicketMessage"     ENABLE ROW LEVEL SECURITY;

-- Reviews
ALTER TABLE "Publish"           ENABLE ROW LEVEL SECURITY;
ALTER TABLE "ReviewImage"       ENABLE ROW LEVEL SECURITY;

-- Contact
ALTER TABLE "ContactMessage"    ENABLE ROW LEVEL SECURITY;

-- GDPR
ALTER TABLE "DataDeletionRequest" ENABLE ROW LEVEL SECURITY;

-- Kanban
ALTER TABLE "KanbanColumn"      ENABLE ROW LEVEL SECURITY;

-- Employee
ALTER TABLE "TimeOffRequest"    ENABLE ROW LEVEL SECURITY;


-- ═══════════════════════════════════════════════
-- 2. Create policies: full access for service roles
-- ═══════════════════════════════════════════════
-- The `postgres` role is used by Prisma (direct DB connection).
-- The `service_role` is Supabase's admin role.
-- Both need unrestricted access. All other access is handled
-- by our NestJS backend (JWT guards, RBAC, etc.).
-- ═══════════════════════════════════════════════

DO $$
DECLARE
    tbl TEXT;
    policy_name TEXT;
BEGIN
    FOR tbl IN
        SELECT unnest(ARRAY[
            'Role', 'Permission', 'RolePermission', 'User', 'UserAddress',
            'PasswordResetToken', 'UserSession', 'UserConsent',
            'WorkingHours', 'Company', 'CompanyOwner', 'CompanyWorkingHours', 'Event',
            'Diet', 'Theme', 'Menu', 'MenuImage', 'Dish', 'Allergen',
            'DishAllergen', 'Ingredient', 'DishIngredient', 'MenuIngredient',
            '_MenuDishes', '_DishAllergens',
            'Order', 'OrderMenu', 'OrderStatusHistory', 'OrderTag', 'OrderOrderTag',
            'DeliveryAssignment',
            'Discount', 'LoyaltyAccount', 'LoyaltyTransaction',
            'Promotion', 'UserPromotion',
            'Message', 'Notification', 'SupportTicket', 'TicketMessage',
            'Publish', 'ReviewImage', 'ContactMessage', 'DataDeletionRequest',
            'KanbanColumn', 'TimeOffRequest'
        ])
    LOOP
        policy_name := 'service_role_full_access_' || replace(replace(tbl, '"', ''), '_', '');

        -- Drop existing policy if any (idempotent)
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', policy_name, tbl);

        -- Create permissive ALL policy for postgres + service_role
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR ALL TO postgres, service_role USING (true) WITH CHECK (true)',
            policy_name, tbl
        );
    END LOOP;
END;
$$;


-- ═══════════════════════════════════════════════
-- 3. Fix function search_path (mutable → immutable)
-- ═══════════════════════════════════════════════
-- Supabase flags functions without an explicit search_path.
-- Setting it to '' (empty) forces fully-qualified references
-- and prevents search_path injection attacks.
-- ═══════════════════════════════════════════════

-- fn_update_timestamp
CREATE OR REPLACE FUNCTION fn_update_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW."updated_at" = NOW();
    RETURN NEW;
END;
$$;

-- fn_order_status_history
CREATE OR REPLACE FUNCTION fn_order_status_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    IF OLD."status" IS DISTINCT FROM NEW."status" THEN
        INSERT INTO public."OrderStatusHistory" ("order_id", "old_status", "new_status", "changed_at")
        VALUES (NEW."id", OLD."status", NEW."status", NOW());
    END IF;
    RETURN NEW;
END;
$$;


-- ═══════════════════════════════════════════════
-- 4. Fix views: SECURITY INVOKER instead of DEFINER
-- ═══════════════════════════════════════════════
-- Supabase flags views with SECURITY DEFINER because
-- they bypass the querying user's RLS policies.
-- Setting security_invoker = true ensures RLS is
-- enforced as the calling user, not the view owner.
-- ═══════════════════════════════════════════════

CREATE OR REPLACE VIEW "v_active_menus"
WITH (security_invoker = true)
AS
SELECT m.*, d."name" AS "diet_name", t."name" AS "theme_name"
FROM "Menu" m
LEFT JOIN "Diet" d ON m."diet_id" = d."id"
LEFT JOIN "Theme" t ON m."theme_id" = t."id"
WHERE m."status" = 'published';

CREATE OR REPLACE VIEW "v_low_stock_ingredients"
WITH (security_invoker = true)
AS
SELECT "id", "name", "unit", "current_stock", "min_stock_level"
FROM "Ingredient"
WHERE "current_stock" <= "min_stock_level";

CREATE OR REPLACE VIEW "v_pending_reviews"
WITH (security_invoker = true)
AS
SELECT p."id", p."note", p."description", p."created_at",
       u."first_name", u."last_name", u."email"
FROM "Publish" p
JOIN "User" u ON p."user_id" = u."id"
WHERE p."status" = 'pending'
ORDER BY p."created_at" ASC;


-- ═══════════════════════════════════════════════
-- 5. Fix materialized view refresh functions
-- ═══════════════════════════════════════════════
-- Recreate with explicit search_path.
-- ═══════════════════════════════════════════════

-- Materialized views (create if not exists — matches cache.sql)
CREATE MATERIALIZED VIEW IF NOT EXISTS "mv_orders_by_status" AS
SELECT
    "status",
    COUNT(*) AS "count",
    COALESCE(SUM("total_price"), 0) AS "total_revenue"
FROM public."Order"
GROUP BY "status";

CREATE MATERIALIZED VIEW IF NOT EXISTS "mv_monthly_revenue" AS
SELECT
    DATE_TRUNC('month', "order_date") AS "month",
    COUNT(*) AS "order_count",
    COALESCE(SUM("total_price"), 0) AS "revenue",
    COALESCE(AVG("total_price"), 0) AS "avg_order_value"
FROM public."Order"
WHERE "status" NOT IN ('cancelled')
GROUP BY DATE_TRUNC('month', "order_date")
ORDER BY "month" DESC;

-- Refresh functions with fixed search_path
CREATE OR REPLACE FUNCTION refresh_mv_orders_by_status()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW public."mv_orders_by_status";
END;
$$;

-- ═══════════════════════════════════════════════
-- 6. Revoke anon/authenticated access to materialized views
-- ═══════════════════════════════════════════════
-- Materialized views are not protected by RLS.
-- Block PostgREST roles from querying them directly.
-- Only postgres/service_role should access these.
-- ═══════════════════════════════════════════════

REVOKE ALL ON "mv_orders_by_status" FROM anon, authenticated;
REVOKE ALL ON "mv_monthly_revenue"  FROM anon, authenticated;

GRANT ALL ON "mv_orders_by_status" TO postgres, service_role;
GRANT ALL ON "mv_monthly_revenue"  TO postgres, service_role;


CREATE OR REPLACE FUNCTION refresh_mv_monthly_revenue()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW public."mv_monthly_revenue";
END;
$$;
