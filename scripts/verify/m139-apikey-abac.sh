#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m139-apikey-abac.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M139 — FINE-GRAINED ABAC (B5): API-KEY callers can flow through the SAME PDP as
# JWT users (so they get the same masks + conditions). Migration 063 seeds
# apikey:read / apikey:write / apikey:admin roles with wildcard policies; the
# query-router, when API_KEY_ABAC_ENABLED=1, maps an api-key's scope to one of
# these roles (apiKeyUuid as the PDP subject) instead of short-circuiting on
# scope. With the flag OFF (default) the existing scope-only path is byte-
# identical — the seeded roles simply have no membership.
#
#   apikey:read  → SELECT on '*'           (read-only)
#   apikey:write → CRUD   on '*'
#   apikey:admin → CRUD   on '*' priority 100
#   a uuid granted apikey:read ⇒ select ALLOW, insert DENY (scope honored via PDP)
#
# NON-VACUITY: the read uuid is allowed select but denied insert — a vacuous
# all-allow projection would let insert through. flag-OFF parity arm asserts the
# scope-only path (decideByApiKeyScope) is still the default in source.
#
# ISOLATED: scratch postgres (prelude + REAL 007 + 063); $$ suffix + EXIT-trap.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
QRY="${INFRA_DIR}/src/apps/query-router/src/query/query.service.ts"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M139] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M139] FAIL — $*"
  exit 1
}

PG_IMAGE="${M139_PG_IMAGE:-postgres:16-alpine}"
PG="m139-pg-$$"
cleanup() { docker rm -fv "${PG}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

# ── 1) static contract + flag-OFF parity ───────────────────────────────────────
step "1/3 static contract — API_KEY_ABAC flag (default OFF) + scope-only fallback intact"
[[ -f "${MIG_DIR}/063_permission_conditions.sql" ]] || fail "migration 063 missing"
grep -q "API_KEY_ABAC_ENABLED" "${QRY}" || fail "QueryService never reads API_KEY_ABAC_ENABLED"
grep -q "apiKeyUuid" "${QRY}" || fail "QueryService lost apiKeyUuid (the PDP subject for api-key callers)"
grep -q "decideByApiKeyScope" "${QRY}" || fail "QueryService lost decideByApiKeyScope (flag-OFF scope-only path)"
# default OFF: the config default must be a falsy literal '0'
grep -q "API_KEY_ABAC_ENABLED', '0'" "${QRY}" || fail "API_KEY_ABAC_ENABLED default is not '0' (must be OFF = byte-parity)"
grep -q "apikey:read\|apikey:write\|apikey:admin" "${MIG_DIR}/063_permission_conditions.sql" ||
  fail "063 does not seed the apikey:* projection roles"
ok "flag default OFF; scope-only fallback intact; apikey:* roles seeded by 063"

# ── 2) boot scratch postgres + REAL 007 + 063 ──────────────────────────────────
step "2/3 boot scratch postgres + apply REAL 007 + 063"
docker run -d --name "${PG}" -e POSTGRES_PASSWORD=postgres "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state"
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email text);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT NULLIF(current_setting('app.current_user_id', true),'')::uuid $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $r$;
SQL
apply "${MIG_DIR}/007_permissions_system.sql" || fail "migration 007 failed"
apply "${MIG_DIR}/063_permission_conditions.sql" || fail "migration 063 failed"
ok "007 + 063 applied"

# ── 3) projection proof ────────────────────────────────────────────────────────
step "3/3 prove api-key scope→role projection honors read-only vs write"
P() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got [$2] want [$3])"; }
P "apikey:read / write / admin roles seeded" \
  "$(val "SELECT count(*) FROM public.roles WHERE name IN ('apikey:read','apikey:write','apikey:admin')")" "3"
RK="55555555-5555-4555-8555-555555555555" # an api-key uuid granted read scope
WK="66666666-6666-4666-8666-666666666666" # write scope
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
INSERT INTO public.user_roles (user_id, role_id) SELECT '${RK}'::uuid, id FROM public.roles WHERE name='apikey:read'  ON CONFLICT DO NOTHING;
INSERT INTO public.user_roles (user_id, role_id) SELECT '${WK}'::uuid, id FROM public.roles WHERE name='apikey:write' ON CONFLICT DO NOTHING;
SQL
P "read scope ⇒ select ALLOW" "$(val "SELECT public.has_permission('${RK}'::uuid,'postgresql','anything','select')")" "t"
P "read scope ⇒ insert DENY" "$(val "SELECT public.has_permission('${RK}'::uuid,'postgresql','anything','insert')")" "f"
P "write scope ⇒ insert ALLOW" "$(val "SELECT public.has_permission('${WK}'::uuid,'postgresql','anything','insert')")" "t"
P "write scope ⇒ delete ALLOW" "$(val "SELECT public.has_permission('${WK}'::uuid,'postgresql','anything','delete')")" "t"
# flag-OFF parity: an unmapped api-key uuid (no membership) gets nothing from the PDP
P "unmapped api-key uuid ⇒ PDP grants nothing (flag-OFF leaves it to scope path)" \
  "$(val "SELECT public.has_permission('77777777-7777-4777-8777-777777777777'::uuid,'postgresql','anything','select')")" "f"

green "[M139] PASS — api-key scope→role projection honors read/write; flag-OFF byte-parity preserved"
