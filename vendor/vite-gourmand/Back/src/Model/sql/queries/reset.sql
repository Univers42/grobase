-- ============================================
-- MASTER PUSH SCRIPT — Supabase / PostgreSQL
-- ============================================
-- Execution order matters (FK dependencies).
--
-- Run with:
--   psql "$DIRECT_URL" -f reset.sql
--
-- From: Back/src/Model/sql/queries/
-- ============================================

\echo '🔴 Dropping all tables...'
\i ../schemas/reset.sql

\echo '🏢 Creating company tables...'
\i ../schemas/orgnanization.sql

\echo '🔐 Creating auth tables...'
\i ../schemas/auth.sql

\echo '🛡️ Creating GDPR tables...'
\i ../schemas/gpdr.sql

\echo '📋 Creating menu tables...'
\i ../schemas/menu.sql

\echo '🎁 Creating loyalty & discount tables...'
\i ../schemas/loyalty.sql

\echo '📦 Creating order tables...'
\i ../schemas/orders.sql

\echo '🏆 Creating loyalty accounts & transactions...'
\i ../schemas/loyalty_post_order.sql

\echo '⭐ Creating review tables...'
\i ../schemas/reviews.sql

\echo '📬 Creating contact tables...'
\i ../schemas/contact.sql

\echo '👷 Creating employee tables...'
\i ../schemas/employee.sql

\echo '💬 Creating messaging tables...'
\i ../schemas/messaging.sql

\echo '📊 Creating kanban tables...'
\i ../schemas/kanban.sql

\echo '⚡ Creating triggers & views...'
\i ../schemas/optimizing.sql

\echo '📈 Creating materialized views...'
\i ../schemas/cache.sql

\echo ''
\echo '🌱 Seeding data...'
\i ../seeds/role.sql
\i ../seeds/permission.sql
\i ../seeds/role_permission.sql
\i ../seeds/user.sql
\i ../seeds/user_address.sql
\i ../seeds/user_session.sql
\i ../seeds/user_content.sql
\i ../seeds/password_token.sql
\i ../seeds/working_hours.sql
\i ../seeds/diet.sql
\i ../seeds/theme.sql
\i ../seeds/allergen.sql
\i ../seeds/ingredient.sql
\i ../seeds/menu.sql
\i ../seeds/dish.sql
\i ../seeds/menu_dish.sql
\i ../seeds/menu_image.sql
\i ../seeds/dish_allergen.sql
\i ../seeds/dish_ingredient.sql
\i ../seeds/menu_ingredient.sql
\i ../seeds/discount.sql
\i ../seeds/order.sql
\i ../seeds/order_status_history.sql
\i ../seeds/loyalty_account.sql
\i ../seeds/loyalty_transaction.sql
\i ../seeds/publish.sql
\i ../seeds/contact_message.sql
\i ../seeds/data_deletion_request.sql
\i ../seeds/time_off_request.sql
\i ../seeds/message.sql
\i ../seeds/notification.sql
\i ../seeds/support_ticket.sql
\i ../seeds/ticket_message.sql
\i ../seeds/kanban_column.sql
\i ../seeds/order_tag.sql
\i ../seeds/order_order_tag.sql

\echo ''
\echo '🔄 Refreshing materialized views...'
REFRESH MATERIALIZED VIEW "mv_orders_by_status";
REFRESH MATERIALIZED VIEW "mv_monthly_revenue";

\echo ''
\echo '✅ DATABASE FULLY SEEDED!'
\echo '   Tables: 36'
\echo '   Test password: Test123!'
\echo '   Admin: jose@vitegourmand.fr'
\echo ''
