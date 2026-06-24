#!/usr/bin/env bash
# ============================================
# Deploy SQL schemas + seeds to Supabase
# Uses DIRECT_URL (session pooler, port 5432)
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SQL_DIR="$PROJECT_ROOT/Back/src/Model/sql"
ENV_FILE="$PROJECT_ROOT/Back/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Load .env ──────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    error "Missing $ENV_FILE — copy from .env.example"
fi

# Extract DIRECT_URL from .env (session pooler, supports DDL)
DIRECT_URL=$(grep '^DIRECT_URL=' "$ENV_FILE" | head -1 | sed 's/^DIRECT_URL=//' | tr -d '"' | tr -d "'")

if [ -z "$DIRECT_URL" ]; then
    error "DIRECT_URL not found in $ENV_FILE"
fi

log "Using Supabase session pooler (DIRECT_URL)"
log "SQL directory: $SQL_DIR"

# ── Validate SQL files exist ──────────────────────────
SCHEMAS_DIR="$SQL_DIR/schemas"
SEEDS_DIR="$SQL_DIR/seeds"

[ -d "$SCHEMAS_DIR" ] || error "Schemas directory not found: $SCHEMAS_DIR"
[ -d "$SEEDS_DIR" ]   || error "Seeds directory not found: $SEEDS_DIR"

# ── Check psql is available ───────────────────────────
command -v psql >/dev/null 2>&1 || error "psql not found. Install: sudo apt install postgresql-client"

# ── Test connection ───────────────────────────────────
log "Testing Supabase connection..."
if ! psql "$DIRECT_URL" -c "SELECT 1;" >/dev/null 2>&1; then
    error "Cannot connect to Supabase. Check DIRECT_URL in $ENV_FILE"
fi
ok "Connected to Supabase"

# ── Helper: run SQL file ─────────────────────────────
run_sql() {
    local file="$1"
    local label="$2"
    if [ ! -f "$file" ]; then
        warn "File not found, skipping: $file"
        return 0
    fi
    log "$label → $(basename "$file")"
    if ! psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$file" 2>&1; then
        error "Failed on: $file"
    fi
}

# ── Confirm destructive action ───────────────────────
echo ""
echo -e "${RED}⚠️  WARNING: This will DROP and RECREATE all tables on Supabase!${NC}"
echo -e "${RED}   All existing data will be destroyed.${NC}"
echo ""
read -rp "Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
log "Starting deployment..."
echo "============================================"

# ── 1. Drop everything ───────────────────────────────
run_sql "$SCHEMAS_DIR/reset.sql" "🔴 Dropping all objects"

# ── 2. Create schemas (order matters for FK) ─────────
run_sql "$SCHEMAS_DIR/orgnanization.sql" "🏢 Company config"
run_sql "$SCHEMAS_DIR/auth.sql"          "🔐 Auth & users"
run_sql "$SCHEMAS_DIR/gpdr.sql"          "🛡️  GDPR"
run_sql "$SCHEMAS_DIR/menu.sql"          "📋 Menu management"
run_sql "$SCHEMAS_DIR/loyalty.sql"       "🎁 Discounts (pre-order)"
run_sql "$SCHEMAS_DIR/orders.sql"        "📦 Orders"
run_sql "$SCHEMAS_DIR/loyalty_post_order.sql" "🏆 Loyalty accounts & transactions"
run_sql "$SCHEMAS_DIR/reviews.sql"       "⭐ Reviews"
run_sql "$SCHEMAS_DIR/contact.sql"       "📬 Contact"
run_sql "$SCHEMAS_DIR/employee.sql"      "👷 Employee management"
run_sql "$SCHEMAS_DIR/messaging.sql"     "💬 Messaging"
run_sql "$SCHEMAS_DIR/kanban.sql"        "📊 Kanban"
run_sql "$SCHEMAS_DIR/optimizing.sql"    "⚡ Triggers & views"
run_sql "$SCHEMAS_DIR/cache.sql"         "📈 Materialized views"
run_sql "$SCHEMAS_DIR/security_rls.sql"  "🔒 RLS & Security policies"

echo ""
echo "============================================"
log "Schemas created. Seeding data..."
echo "============================================"
echo ""

# ── 3. Seed data (order matters for FK) ──────────────
run_sql "$SEEDS_DIR/role.sql"               "🌱 Roles"
run_sql "$SEEDS_DIR/permission.sql"         "🌱 Permissions"
run_sql "$SEEDS_DIR/role_permission.sql"    "🌱 Role-Permission mapping"
run_sql "$SEEDS_DIR/user.sql"               "🌱 Users"
run_sql "$SEEDS_DIR/user_address.sql"       "🌱 User addresses"
run_sql "$SEEDS_DIR/user_session.sql"       "🌱 User sessions"
run_sql "$SEEDS_DIR/user_content.sql"       "🌱 User consents"
run_sql "$SEEDS_DIR/password_token.sql"     "🌱 Password tokens"
run_sql "$SEEDS_DIR/working_hours.sql"      "🌱 Working hours"
run_sql "$SEEDS_DIR/company.sql"            "🌱 Company"
run_sql "$SEEDS_DIR/company_owner.sql"      "🌱 Company owners"
run_sql "$SEEDS_DIR/company_working_hours.sql" "🌱 Company working hours"
run_sql "$SEEDS_DIR/event.sql"              "🌱 Events"
run_sql "$SEEDS_DIR/diet.sql"               "🌱 Diets"
run_sql "$SEEDS_DIR/theme.sql"              "🌱 Themes"
run_sql "$SEEDS_DIR/allergen.sql"           "🌱 Allergens"
run_sql "$SEEDS_DIR/ingredient.sql"         "🌱 Ingredients"
run_sql "$SEEDS_DIR/menu.sql"               "🌱 Menus"
run_sql "$SEEDS_DIR/dish.sql"               "🌱 Dishes"
run_sql "$SEEDS_DIR/menu_dish.sql"          "🌱 Menu-Dish junctions"
run_sql "$SEEDS_DIR/menu_image.sql"         "🌱 Menu images"
run_sql "$SEEDS_DIR/dish_allergen.sql"      "🌱 Dish allergens"
run_sql "$SEEDS_DIR/dish_ingredient.sql"    "🌱 Dish ingredients"
run_sql "$SEEDS_DIR/menu_ingredient.sql"    "🌱 Menu ingredients"
run_sql "$SEEDS_DIR/discount.sql"           "🌱 Discounts"
run_sql "$SEEDS_DIR/promotion.sql"          "🌱 Promotions"
run_sql "$SEEDS_DIR/user_promotion.sql"     "🌱 User Promotions"
run_sql "$SEEDS_DIR/order.sql"              "🌱 Orders"
run_sql "$SEEDS_DIR/order_status_history.sql" "🌱 Order status history"
run_sql "$SEEDS_DIR/loyalty_account.sql"    "🌱 Loyalty accounts"
run_sql "$SEEDS_DIR/loyalty_transaction.sql" "🌱 Loyalty transactions"
run_sql "$SEEDS_DIR/publish.sql"            "🌱 Reviews (Publish)"
run_sql "$SEEDS_DIR/contact_message.sql"    "🌱 Contact messages"
run_sql "$SEEDS_DIR/data_deletion_request.sql" "🌱 GDPR deletion requests"
run_sql "$SEEDS_DIR/time_off_request.sql"   "🌱 Time-off requests"
run_sql "$SEEDS_DIR/message.sql"            "🌱 Messages"
run_sql "$SEEDS_DIR/notification.sql"       "🌱 Notifications"
run_sql "$SEEDS_DIR/support_ticket.sql"     "🌱 Support tickets"
run_sql "$SEEDS_DIR/ticket_message.sql"     "🌱 Ticket messages"
run_sql "$SEEDS_DIR/kanban_column.sql"      "🌱 Kanban columns"
run_sql "$SEEDS_DIR/order_tag.sql"          "🌱 Order tags"
run_sql "$SEEDS_DIR/order_order_tag.sql"    "🌱 Order-Tag junctions"

# ── 4. Refresh materialized views ────────────────────
echo ""
log "🔄 Refreshing materialized views..."
psql "$DIRECT_URL" -c 'REFRESH MATERIALIZED VIEW "mv_orders_by_status";' 2>&1 || warn "Could not refresh mv_orders_by_status"
psql "$DIRECT_URL" -c 'REFRESH MATERIALIZED VIEW "mv_monthly_revenue";' 2>&1 || warn "Could not refresh mv_monthly_revenue"

# ── 5. Validate ──────────────────────────────────────
echo ""
log "🔍 Validating deployment..."
TABLE_COUNT=$(psql "$DIRECT_URL" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';")
VIEW_COUNT=$(psql "$DIRECT_URL" -t -c "SELECT COUNT(*) FROM information_schema.views WHERE table_schema = 'public';")
MATVIEW_COUNT=$(psql "$DIRECT_URL" -t -c "SELECT COUNT(*) FROM pg_matviews WHERE schemaname = 'public';")
USER_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "User";')
MENU_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "Menu";')
ORDER_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "Order";')

echo ""
echo "============================================"
ok "✅ DEPLOYMENT COMPLETE!"
echo "============================================"
echo ""
echo "  📊 Tables:             $(echo $TABLE_COUNT | xargs)"
echo "  👁️  Views:              $(echo $VIEW_COUNT | xargs)"
echo "  📈 Materialized Views: $(echo $MATVIEW_COUNT | xargs)"
echo "  👤 Users seeded:       $(echo $USER_COUNT | xargs)"
echo "  📋 Menus seeded:       $(echo $MENU_COUNT | xargs)"
echo "  📦 Orders seeded:      $(echo $ORDER_COUNT | xargs)"
echo ""
echo "  🔑 Test password:  Test123!"
echo "  👤 Admin login:    jose@vitegourmand.fr"
echo "  👤 Superadmin:     dylan@vitegourmand.dev"
echo ""
