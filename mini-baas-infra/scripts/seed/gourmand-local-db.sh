#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    gourmand-local-db.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# DEV SUBSTRATE: reproduce vite-gourmand's REAL database (their own checked-in
# schema + seeds, exact FK load order from scripts/supabase/deploy-supabase.sh)
# in a `gourmand` database on the mini-baas postgres, so the live-database
# onboarding can be exercised end to end without a reachable Supabase project.
# The tables are byte-identical to production (PascalCase, same columns, same
# enums-as-text) — only the host differs. When a real Supabase DSN exists,
# skip this script and pass GOURMAND_DB_DSN to gourmand-tenant.sh instead.
#
# Skips reset.sql (drops everything — only for their own re-deploys) and
# security_rls.sql (references Supabase's auth.uid(), absent here; the mount
# connects as a BYPASSRLS superuser anyway). Idempotent: schema files use
# CREATE TABLE IF NOT EXISTS, seeds use ON CONFLICT — re-runs converge.
#
# Emits GOURMAND_DB_DSN to stdout (the in-network DSN the mount should use).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
VG_SQL="${REPO_ROOT}/apps/vite-gourmand/Back/src/Model/sql"
PG_CTN="mini-baas-postgres"
DB="gourmand"

cyan() { printf '\033[0;36m[gourmand-localdb] %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[0;31m[gourmand-localdb] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "${VG_SQL}/schemas" ]] || fail "vite-gourmand SQL not found at ${VG_SQL}"
docker inspect "${PG_CTN}" >/dev/null 2>&1 || fail "${PG_CTN} not running"
PG_USER="$(docker inspect "${PG_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_USER=//p' | head -1)"; PG_USER="${PG_USER:-postgres}"
PG_PASS="$(docker inspect "${PG_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_PASSWORD=//p' | head -1)"

PSQL() { docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -v ON_ERROR_STOP=1 "$@"; }
LOAD() { # $1 db, $2 file, $3 label
  [[ -f "$2" ]] || { cyan "skip ${3} (no $2)"; return 0; }
  PSQL -q -d "$1" < "$2" >/dev/null 2>/tmp/gourmand-localdb.err \
    || fail "${3} failed: $(tail -2 /tmp/gourmand-localdb.err)"
}

cyan "ensuring database '${DB}' on ${PG_CTN}"
PSQL -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='${DB}'" | grep -q 1 \
  || PSQL -d postgres -c "CREATE DATABASE ${DB}" >/dev/null

# ── schemas (FK order; reset + RLS deliberately excluded) ────────────────────
cyan "applying schema (PascalCase tables, their FK order)"
# auth FIRST (creates "User"/"Role" — orgnanization.CompanyOwner FKs them;
# their deploy-supabase.sh lists orgnanization first, which only works because
# Supabase ships auth.users — on a plain Postgres "User" must exist first).
for s in auth orgnanization gpdr menu loyalty orders loyalty_post_order reviews \
         contact employee messaging kanban promotions newsletter optimizing; do
  LOAD "${DB}" "${VG_SQL}/schemas/${s}.sql" "schema ${s}"
done

# ── seeds (FK order; only the files that exist) ──────────────────────────────
cyan "applying seed data (their FK order)"
for d in role permission role_permission user user_address user_session user_content \
         password_token working_hours company company_owner company_working_hours \
         event diet theme allergen ingredient menu dish menu_dish menu_image \
         dish_allergen dish_ingredient menu_ingredient discount promotion \
         user_promotion order_tag order order_order_tag order_status_history \
         loyalty_account loyalty_transaction publish contact_message \
         data_deletion_request time_off_request message notification \
         support_ticket ticket_message kanban_column newsletter_subscriber; do
  # Seeds are best-effort: a missing optional seed or a benign ON CONFLICT is
  # not fatal (the schema is what the mount needs; data just makes it lively).
  if [[ -f "${VG_SQL}/seeds/${d}.sql" ]]; then
    docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -d "${DB}" -q \
      < "${VG_SQL}/seeds/${d}.sql" >/dev/null 2>>/tmp/gourmand-localdb.seed.err || cyan "seed ${d}: non-fatal issue (continuing)"
  fi
done

tables="$(PSQL -d "${DB}" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
orders="$(PSQL -d "${DB}" -tAc "SELECT count(*) FROM \"Order\"" 2>/dev/null || echo 0)"
cyan "loaded ${tables} tables; \"Order\" has ${orders} rows"
[[ "${tables}" -ge 40 ]] || fail "only ${tables} tables created — schema load incomplete"

printf 'postgres://%s:%s@postgres:5432/%s\n' "${PG_USER}" "${PG_PASS}" "${DB}"
cyan "OK — GOURMAND_DB_DSN printed to stdout (in-network)"
