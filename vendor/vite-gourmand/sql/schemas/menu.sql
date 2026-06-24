-- ============================================
-- SCHEMA: Menu management
-- ============================================

CREATE TABLE IF NOT EXISTS "Diet" (
    "id"          SERIAL PRIMARY KEY,
    "name"        VARCHAR(100) UNIQUE NOT NULL,
    "description" TEXT,
    "icon_url"    VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS "Theme" (
    "id"          SERIAL PRIMARY KEY,
    "name"        VARCHAR(100) UNIQUE NOT NULL,
    "description" TEXT,
    "icon_url"    VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS "Menu" (
    "id"               SERIAL PRIMARY KEY,
    "title"            VARCHAR(255) NOT NULL,
    "description"      TEXT,
    "conditions"       TEXT,
    "person_min"       INT NOT NULL,
    "price_per_person" DECIMAL(10,2) NOT NULL,
    "remaining_qty"    INT NOT NULL DEFAULT 0,
    "status"           VARCHAR(20) DEFAULT 'published',
    "diet_id"          INT REFERENCES "Diet"("id"),
    "theme_id"         INT REFERENCES "Theme"("id"),
    "created_by"       INT REFERENCES "User"("id"),
    "is_seasonal"      BOOLEAN DEFAULT FALSE,
    "available_from"   DATE,
    "available_until"  DATE,
    "created_at"       TIMESTAMPTZ DEFAULT NOW(),
    "updated_at"       TIMESTAMPTZ DEFAULT NOW(),
    "published_at"     TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_menu_status ON "Menu"("status");
CREATE INDEX IF NOT EXISTS idx_menu_title ON "Menu"("title");

CREATE TABLE IF NOT EXISTS "MenuImage" (
    "id"            SERIAL PRIMARY KEY,
    "menu_id"       INT NOT NULL REFERENCES "Menu"("id") ON DELETE CASCADE,
    "image_url"     VARCHAR(500) NOT NULL,
    "alt_text"      VARCHAR(255),
    "display_order" INT DEFAULT 0,
    "is_primary"    BOOLEAN DEFAULT FALSE,
    "uploaded_at"   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS "Dish" (
    "id"          SERIAL PRIMARY KEY,
    "title"       VARCHAR(255) NOT NULL,
    "description" TEXT,
    "photo_url"   VARCHAR(500),
    "course_type" VARCHAR(20) DEFAULT 'plat',
    "created_at"  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dish_course ON "Dish"("course_type");

-- Prisma implicit M:N format
CREATE TABLE IF NOT EXISTS "_MenuDishes" (
    "A" INT NOT NULL REFERENCES "Dish"("id") ON DELETE CASCADE,
    "B" INT NOT NULL REFERENCES "Menu"("id") ON DELETE CASCADE,
    PRIMARY KEY ("A", "B")
);
CREATE INDEX IF NOT EXISTS idx_menu_dishes_b ON "_MenuDishes"("B");

CREATE TABLE IF NOT EXISTS "Allergen" (
    "id"       SERIAL PRIMARY KEY,
    "name"     VARCHAR(100) UNIQUE NOT NULL,
    "icon_url" VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS "_DishAllergens" (
    "A" INT NOT NULL REFERENCES "Allergen"("id") ON DELETE CASCADE,
    "B" INT NOT NULL REFERENCES "Dish"("id") ON DELETE CASCADE,
    PRIMARY KEY ("A", "B")
);
CREATE INDEX IF NOT EXISTS idx_dish_allergens_b ON "_DishAllergens"("B");

-- Explicit named junction for dish-allergen (used by Prisma explicit M:N)
CREATE TABLE IF NOT EXISTS "DishAllergen" (
    "dish_id"     INT NOT NULL REFERENCES "Dish"("id") ON DELETE CASCADE,
    "allergen_id" INT NOT NULL REFERENCES "Allergen"("id") ON DELETE CASCADE,
    PRIMARY KEY ("dish_id", "allergen_id")
);
CREATE INDEX IF NOT EXISTS idx_dish_allergen_allergen ON "DishAllergen"("allergen_id");

CREATE TABLE IF NOT EXISTS "Ingredient" (
    "id"                SERIAL PRIMARY KEY,
    "name"              VARCHAR(255) UNIQUE NOT NULL,
    "unit"              VARCHAR(20) DEFAULT 'kg',
    "current_stock"     DECIMAL(10,2) DEFAULT 0,
    "min_stock_level"   DECIMAL(10,2) DEFAULT 0,
    "cost_per_unit"     DECIMAL(10,2),
    "last_restocked_at" TIMESTAMPTZ,
    "created_at"        TIMESTAMPTZ DEFAULT NOW(),
    "updated_at"        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS "DishIngredient" (
    "dish_id"       INT NOT NULL REFERENCES "Dish"("id") ON DELETE CASCADE,
    "ingredient_id" INT NOT NULL REFERENCES "Ingredient"("id") ON DELETE CASCADE,
    "quantity"      DECIMAL(10,3) NOT NULL,
    PRIMARY KEY ("dish_id", "ingredient_id")
);

CREATE TABLE IF NOT EXISTS "MenuIngredient" (
    "menu_id"            INT NOT NULL REFERENCES "Menu"("id") ON DELETE CASCADE,
    "ingredient_id"      INT NOT NULL REFERENCES "Ingredient"("id") ON DELETE CASCADE,
    "quantity_per_person" DECIMAL(10,3) NOT NULL,
    PRIMARY KEY ("menu_id", "ingredient_id")
);
