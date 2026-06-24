#!/usr/bin/env bash
# ============================================
# RESET DATABASE SCRIPT
# ============================================
# Complete database reset with:
#   1. Drop all tables & objects
#   2. Deploy schemas
#   3. Seed data (including new Company, Event tables)
#   4. Introspect with Prisma
#   5. Update menu images
#   6. Validate and show output
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="$PROJECT_ROOT/Back"
SQL_DIR="$BACKEND_DIR/src/Model/sql"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
ENV_FILE="$BACKEND_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

log()     { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${MAGENTA}════════════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  $1${NC}"; echo -e "${MAGENTA}════════════════════════════════════════════${NC}\n"; }

# ── Load .env ──────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    error "Missing $ENV_FILE — copy from .env.example"
fi

DIRECT_URL=$(grep '^DIRECT_URL=' "$ENV_FILE" | head -1 | sed 's/^DIRECT_URL=//' | tr -d '"' | tr -d "'")
if [ -z "$DIRECT_URL" ]; then
    error "DIRECT_URL not found in $ENV_FILE"
fi

# ── Check dependencies ────────────────────────────────
command -v psql >/dev/null 2>&1 || error "psql not found. Install: sudo apt install postgresql-client"
command -v npx >/dev/null 2>&1 || error "npx not found. Install Node.js first."

# ── Confirm destructive action ───────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  ⚠️   WARNING: COMPLETE DATABASE RESET                        ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  This will:                                                  ║${NC}"
echo -e "${RED}║    • DROP all tables, views, and functions                   ║${NC}"
echo -e "${RED}║    • RECREATE all schemas from SQL files                     ║${NC}"
echo -e "${RED}║    • SEED all data (users, menus, orders, reviews, etc.)     ║${NC}"
echo -e "${RED}║    • Regenerate Prisma schema via introspection              ║${NC}"
echo -e "${RED}║    • Update menu images from Unsplash                        ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  ALL EXISTING DATA WILL BE PERMANENTLY DESTROYED!            ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -rp "Type 'RESET' to confirm: " CONFIRM
if [ "$CONFIRM" != "RESET" ]; then
    echo "Aborted."
    exit 0
fi

START_TIME=$(date +%s)

# ── Test connection ───────────────────────────────────
section "1/7 — Testing Database Connection"
log "Connecting to Supabase..."
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
    # Run psql with ON_ERROR_STOP for real error detection, filter noise
    local output
    output=$(psql "$DIRECT_URL" -v ON_ERROR_STOP=1 -f "$file" 2>&1) || {
        # Show only the actual ERROR lines
        echo "$output" | grep -E "ERROR:" | head -5
        error "Failed on: $file"
    }
}

SCHEMAS_DIR="$SQL_DIR/schemas"
SEEDS_DIR="$SQL_DIR/seeds"

# ── 2. Drop everything ───────────────────────────────
section "2/7 — Dropping All Objects"
run_sql "$SCHEMAS_DIR/reset.sql" "🔴 Dropping all objects"
ok "All objects dropped"

# ── 3. Create schemas (order matters for FK) ─────────
section "3/7 — Creating Schemas"
run_sql "$SCHEMAS_DIR/auth.sql"          "🔐 Auth & Users"
run_sql "$SCHEMAS_DIR/orgnanization.sql" "🏢 Company & Organization"
run_sql "$SCHEMAS_DIR/gpdr.sql"          "🛡️  GDPR"
run_sql "$SCHEMAS_DIR/menu.sql"          "📋 Menu Management"
run_sql "$SCHEMAS_DIR/loyalty.sql"       "🎁 Discounts (pre-order)"
run_sql "$SCHEMAS_DIR/promotions.sql"    "📢 Promotions & Publicity"
run_sql "$SCHEMAS_DIR/newsletter.sql"    "📬 Newsletter"
run_sql "$SCHEMAS_DIR/orders.sql"        "📦 Orders"
run_sql "$SCHEMAS_DIR/loyalty_post_order.sql" "🏆 Loyalty"
run_sql "$SCHEMAS_DIR/reviews.sql"       "⭐ Reviews"
run_sql "$SCHEMAS_DIR/contact.sql"       "📬 Contact"
run_sql "$SCHEMAS_DIR/employee.sql"      "👷 Employee"
run_sql "$SCHEMAS_DIR/messaging.sql"     "💬 Messaging"
run_sql "$SCHEMAS_DIR/kanban.sql"        "📊 Kanban"
run_sql "$SCHEMAS_DIR/optimizing.sql"    "⚡ Triggers & Views"
run_sql "$SCHEMAS_DIR/cache.sql"         "📈 Materialized Views"
run_sql "$SCHEMAS_DIR/security_rls.sql"  "🔒 RLS & Security Policies"
ok "All schemas created (with RLS enabled)"

# ── 4. Seed data (order matters for FK) ──────────────
section "4/7 — Seeding Data"

# Core auth
run_sql "$SEEDS_DIR/role.sql"               "🌱 Roles"
run_sql "$SEEDS_DIR/permission.sql"         "🌱 Permissions"
run_sql "$SEEDS_DIR/role_permission.sql"    "🌱 Role-Permission"
run_sql "$SEEDS_DIR/user.sql"               "🌱 Users"
run_sql "$SEEDS_DIR/user_address.sql"       "🌱 User Addresses"
run_sql "$SEEDS_DIR/user_session.sql"       "🌱 User Sessions"
run_sql "$SEEDS_DIR/user_content.sql"       "🌱 User Consents"
run_sql "$SEEDS_DIR/password_token.sql"     "🌱 Password Tokens"

# Organization (NEW)
run_sql "$SEEDS_DIR/working_hours.sql"      "🌱 Working Hours"
run_sql "$SEEDS_DIR/company.sql"            "🌱 Company"
run_sql "$SEEDS_DIR/company_owner.sql"      "🌱 Company Owners"
run_sql "$SEEDS_DIR/company_working_hours.sql" "🌱 Company Working Hours"
run_sql "$SEEDS_DIR/event.sql"              "🌱 Events"

# Menu system
run_sql "$SEEDS_DIR/diet.sql"               "🌱 Diets"
run_sql "$SEEDS_DIR/theme.sql"              "🌱 Themes"
run_sql "$SEEDS_DIR/allergen.sql"           "🌱 Allergens"
run_sql "$SEEDS_DIR/ingredient.sql"         "🌱 Ingredients"
run_sql "$SEEDS_DIR/menu.sql"               "🌱 Menus"
run_sql "$SEEDS_DIR/dish.sql"               "🌱 Dishes"
run_sql "$SEEDS_DIR/menu_dish.sql"          "🌱 Menu-Dish"
run_sql "$SEEDS_DIR/menu_image.sql"         "🌱 Menu Images"
run_sql "$SEEDS_DIR/dish_allergen.sql"      "🌱 Dish Allergens"
run_sql "$SEEDS_DIR/dish_ingredient.sql"    "🌱 Dish Ingredients"
run_sql "$SEEDS_DIR/menu_ingredient.sql"    "🌱 Menu Ingredients"

# Orders & loyalty
run_sql "$SEEDS_DIR/discount.sql"           "🌱 Discounts"
run_sql "$SEEDS_DIR/promotion.sql"          "🌱 Promotions"
run_sql "$SEEDS_DIR/user_promotion.sql"     "🌱 User Promotions"
run_sql "$SEEDS_DIR/newsletter_subscriber.sql" "🌱 Newsletter Subscribers"
run_sql "$SEEDS_DIR/order.sql"              "🌱 Orders"
run_sql "$SEEDS_DIR/order_status_history.sql" "🌱 Order History"
run_sql "$SEEDS_DIR/loyalty_account.sql"    "🌱 Loyalty Accounts"
run_sql "$SEEDS_DIR/loyalty_transaction.sql" "🌱 Loyalty Transactions"

# Reviews & contact
run_sql "$SEEDS_DIR/publish.sql"            "🌱 Reviews (Publish)"
run_sql "$SEEDS_DIR/contact_message.sql"    "🌱 Contact Messages"
run_sql "$SEEDS_DIR/data_deletion_request.sql" "🌱 GDPR Requests"

# Employee & messaging
run_sql "$SEEDS_DIR/time_off_request.sql"   "🌱 Time-off Requests"
run_sql "$SEEDS_DIR/message.sql"            "🌱 Messages"
run_sql "$SEEDS_DIR/notification.sql"       "🌱 Notifications"
run_sql "$SEEDS_DIR/support_ticket.sql"     "🌱 Support Tickets"
run_sql "$SEEDS_DIR/ticket_message.sql"     "🌱 Ticket Messages"

# Kanban
run_sql "$SEEDS_DIR/kanban_column.sql"      "🌱 Kanban Columns"
run_sql "$SEEDS_DIR/order_tag.sql"          "🌱 Order Tags"
run_sql "$SEEDS_DIR/order_order_tag.sql"    "🌱 Order-Tag"

ok "All data seeded"

# ── 5. Refresh materialized views ────────────────────
section "5/7 — Refreshing Materialized Views"
log "Refreshing mv_orders_by_status..."
psql "$DIRECT_URL" -c 'REFRESH MATERIALIZED VIEW "mv_orders_by_status";' 2>/dev/null || warn "Could not refresh mv_orders_by_status"
log "Refreshing mv_monthly_revenue..."
psql "$DIRECT_URL" -c 'REFRESH MATERIALIZED VIEW "mv_monthly_revenue";' 2>/dev/null || warn "Could not refresh mv_monthly_revenue"
ok "Materialized views refreshed"

# ── 6. Prisma introspection ──────────────────────────
section "6/7 — Prisma Introspection"
if [ -f "$SCRIPTS_DIR/supabase/prisma-introspect.sh" ]; then
    log "Running Prisma introspection..."
    bash "$SCRIPTS_DIR/supabase/prisma-introspect.sh" 2>&1 | tail -20 || warn "Introspection had warnings"
    ok "Prisma schema regenerated"
else
    warn "prisma-introspect.sh not found, skipping..."
fi

# ── 7. Update menu images ────────────────────────────
section "7/7 — Updating Menu Images"
if [ -f "$BACKEND_DIR/scripts/update-menu-images.ts" ]; then
    log "Updating menu images from Unsplash..."
    cd "$BACKEND_DIR"
    npx ts-node scripts/update-menu-images.ts 2>&1 | tail -10 || warn "Image update had issues"
    ok "Menu images updated"
else
    warn "update-menu-images.ts not found, skipping..."
fi

# ── Validation & Summary ─────────────────────────────
section "VALIDATION & SUMMARY"

log "Querying database statistics..."

# Get counts
TABLE_COUNT=$(psql "$DIRECT_URL" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';" | xargs)
VIEW_COUNT=$(psql "$DIRECT_URL" -t -c "SELECT COUNT(*) FROM information_schema.views WHERE table_schema = 'public';" | xargs)
MATVIEW_COUNT=$(psql "$DIRECT_URL" -t -c "SELECT COUNT(*) FROM pg_matviews WHERE schemaname = 'public';" | xargs)
USER_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "User";' | xargs)
MENU_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "Menu";' | xargs)
ORDER_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "Order";' | xargs)
REVIEW_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "Publish";' | xargs)
APPROVED_REVIEWS=$(psql "$DIRECT_URL" -t -c "SELECT COUNT(*) FROM \"Publish\" WHERE status = 'approved';" | xargs)
COMPANY_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "Company";' 2>/dev/null | xargs || echo "0")
EVENT_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "Event";' 2>/dev/null | xargs || echo "0")
WORKING_HOURS_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "WorkingHours";' | xargs)
PROMOTION_COUNT=$(psql "$DIRECT_URL" -t -c 'SELECT COUNT(*) FROM "Promotion";' 2>/dev/null | xargs || echo "0")
ACTIVE_PROMOS=$(psql "$DIRECT_URL" -t -c "SELECT COUNT(*) FROM \"Promotion\" WHERE is_active = TRUE AND start_date <= NOW() AND (end_date IS NULL OR end_date >= NOW());" 2>/dev/null | xargs || echo "0")

# Calculate elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  DATABASE RESET COMPLETE!                                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│  📊 DATABASE STATISTICS                                      │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Tables:" "$TABLE_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Views:" "$VIEW_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Materialized Views:" "$MATVIEW_COUNT"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Users:" "$USER_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Menus:" "$MENU_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Orders:" "$ORDER_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Reviews (total):" "$REVIEW_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Reviews (approved):" "$APPROVED_REVIEWS"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Companies:" "$COMPANY_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Events:" "$EVENT_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Working Hours:" "$WORKING_HOURS_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Promotions (total):" "$PROMOTION_COUNT"
printf "${CYAN}│${NC}  %-30s %25s ${CYAN}│${NC}\n" "Promotions (active now):" "$ACTIVE_PROMOS"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│  🔑 TEST CREDENTIALS                                         │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│${NC}  Password:     ${YELLOW}Test123!${NC}                                    ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  Superadmin:   ${YELLOW}dylan@vitegourmand.dev${NC}                      ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  Admin (José): ${YELLOW}jose@vitegourmand.fr${NC}                        ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  Admin (Julie): ${YELLOW}julie@vitegourmand.fr${NC}                      ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  Client:       ${YELLOW}alice@example.fr${NC}                            ${CYAN}│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  ⏱️  Completed in ${BOLD}${ELAPSED}s${NC}"
echo ""

# ── Show table listing ───────────────────────────────
section "ALL TABLES"
psql "$DIRECT_URL" -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"

echo ""
ok "Database is ready for use!"
