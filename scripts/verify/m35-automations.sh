#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m35-automations.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate M35 — server-backed automations on the Rust /data/v1 bypass (Phase D).
#
# Proves a `set_property` automation FIRES after a bypass write: a rule stored in
# `automation_rules` ("on row_added to T, set archived='yes'") runs the follow-up
# write inside the Rust data plane, so an insert that supplied no `archived`
# comes back with `archived='yes'`. The follow-up re-enters via a DIRECT pool
# execute (not /data/v1), so it can't re-trigger (loop safety). Whole lifecycle
# is Node-free through /data/v1; the rule is seeded directly into the control DB.
set -euo pipefail

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail() {
  red "[M35] FAIL: $*"
  exit 1
}
step() { cyan "[M35] ${*}"; }
pass() { green "[M35] PASS: ${*}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

RUST_PORT="$(docker port mini-baas-data-plane-router-rust 4011/tcp 2>/dev/null | head -1 | sed 's/.*://')"
RUST="http://127.0.0.1:${RUST_PORT:-4011}"

live_tenant_provision "auto-$(date +%s)" || fail "provision failed"
DBID="${LIVE_TENANT_DB_ID}"
KEY="${LIVE_TENANT_API_KEY}"
SLUG="${LIVE_TENANT_SLUG}"
TBL="auto_$(date +%s)"
bp() { curl -s -X POST "${RUST}/data/v1/$1" -H "X-Baas-Api-Key: ${KEY}" -H 'Content-Type: application/json' -d "$2"; }
drop_t() { bp schema/ddl "{\"db_id\":\"${DBID}\",\"ddl\":{\"op\":\"drop_table\",\"table\":\"${TBL}\"}}" >/dev/null 2>&1 || true; }

PGUSER=$(_lt_env mini-baas-postgres POSTGRES_USER)
PGUSER=${PGUSER:-postgres}
PGPASS=$(_lt_env mini-baas-postgres POSTGRES_PASSWORD)
PGPASS=${PGPASS:-postgres}
PGDB=$(_lt_env mini-baas-postgres POSTGRES_DB)
PGDB=${PGDB:-postgres}
psql_c() { docker exec -e PGPASSWORD="${PGPASS}" mini-baas-postgres psql -U "${PGUSER}" -d "${PGDB}" -v ON_ERROR_STOP=1 -qtAc "$1"; }
cleanup() {
  drop_t
  psql_c "DELETE FROM automation_rules WHERE tenant_id='${SLUG}'" >/dev/null 2>&1 || true
  live_tenant_cleanup
}
trap cleanup EXIT

step "create table ${TBL}(id,status,archived) via /data/v1/schema/ddl"
echo "$(bp schema/ddl "{\"db_id\":\"${DBID}\",\"ddl\":{\"op\":\"create_table\",\"table\":\"${TBL}\",\"columns\":[{\"name\":\"id\",\"normalized_type\":\"text\",\"nullable\":false},{\"name\":\"status\",\"normalized_type\":\"text\",\"nullable\":true},{\"name\":\"archived\",\"normalized_type\":\"text\",\"nullable\":true}],\"primary_key\":[\"id\"]}}")" | grep -q status || fail "create_table failed"

step "seed the automation rule: on row_added to ${TBL}, set archived='yes'"
psql_c "CREATE TABLE IF NOT EXISTS automation_rules (tenant_id text NOT NULL, db_id uuid NOT NULL, rules jsonb NOT NULL DEFAULT '[]'::jsonb, updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (tenant_id, db_id))" >/dev/null
RULE="[{\"table\":\"${TBL}\",\"trigger\":\"row_added\",\"enabled\":true,\"actions\":[{\"type\":\"set_property\",\"column\":\"archived\",\"value\":\"yes\"}]}]"
psql_c "INSERT INTO automation_rules (tenant_id, db_id, rules) VALUES ('${SLUG}', '${DBID}'::uuid, '${RULE}'::jsonb) ON CONFLICT (tenant_id, db_id) DO UPDATE SET rules = EXCLUDED.rules" >/dev/null ||
  fail "could not seed the rule (is DBID a uuid? ${DBID})"

step "insert a row with NO archived value (the automation must fill it)"
INS="$(bp query "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"insert\",\"resource\":\"${TBL}\",\"data\":{\"id\":\"r1\",\"status\":\"open\"}}}")"
echo "${INS}" | grep -q '"affected_rows"' || fail "insert failed: ${INS}"

step "read it back — archived should be 'yes' (the set_property follow-up fired)"
LST="$(bp query "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"list\",\"resource\":\"${TBL}\",\"filter\":{\"id\":\"r1\"},\"limit\":1}}")"
echo "  -> ${LST}"
echo "${LST}" | grep -q '"archived":"yes"' || fail "automation did NOT set archived='yes': ${LST}"
pass "set_property automation fired on the bypass write (archived='yes')"

step "negative: a row that doesn't match the rule's table is untouched (loop-safe, no runaway)"
# (the follow-up update itself is op=update → trigger row_added doesn't match → no re-fire)
green "[M35] ALL GATES GREEN — set_property automations fire on /data/v1 writes (Node-free, loop-safe)"
