-- ============================================
-- SCHEMA: Triggers, functions, views
-- ============================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION fn_update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW."updated_at" = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to mutable tables
DO $$ BEGIN
    CREATE TRIGGER trg_user_updated BEFORE UPDATE ON "User"
        FOR EACH ROW EXECUTE FUNCTION fn_update_timestamp();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TRIGGER trg_menu_updated BEFORE UPDATE ON "Menu"
        FOR EACH ROW EXECUTE FUNCTION fn_update_timestamp();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TRIGGER trg_order_updated BEFORE UPDATE ON "Order"
        FOR EACH ROW EXECUTE FUNCTION fn_update_timestamp();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TRIGGER trg_publish_updated BEFORE UPDATE ON "Publish"
        FOR EACH ROW EXECUTE FUNCTION fn_update_timestamp();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Auto-track order status changes
CREATE OR REPLACE FUNCTION fn_order_status_history()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD."status" IS DISTINCT FROM NEW."status" THEN
        INSERT INTO "OrderStatusHistory" ("order_id", "old_status", "new_status", "changed_at")
        VALUES (NEW."id", OLD."status", NEW."status", NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN
    CREATE TRIGGER trg_order_status AFTER UPDATE ON "Order"
        FOR EACH ROW EXECUTE FUNCTION fn_order_status_history();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ============================================
-- Useful views
-- ============================================

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
