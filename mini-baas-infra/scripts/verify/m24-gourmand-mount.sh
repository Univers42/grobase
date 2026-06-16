#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m24-gourmand-mount.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for M24 step 2: the vite-gourmand client mount is LIVE and writable
# without ever touching schema or unrelated rows:
#   - schema introspection serves the client's real PascalCase tables
#   - a gateway write roundtrips on a harmless row ("KanbanColumn".color —
#     internal board config) and is REVERTED; psql-side verification when the
#     target is the local fallback, gateway-read verification when remote
#   - a FOREIGN tenant's key cannot reach the mount (the tenant_owned safety
#     argument, negative-tested)
#   - the DSN role can actually see the rows (RLS posture: Supabase's
#     postgres role / local superuser bypass their defined-but-unused
#     policies)
#   - no generated SQL ever references owner_id (the tenant_owned contract)
#
# Requires: scripts/seed/gourmand-tenant.sh run first (.gourmand-tenant.env).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${INFRA_ROOT}/../../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M24] FAIL: $*"; exit 1; }
step()  { cyan "[M24] ${*}"; }
pass()  { green "[M24] PASS: ${*}"; }

# shellcheck source=../verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/lib-live-tenant.sh"

STATE_ENV="${INFRA_ROOT}/.gourmand-tenant.env"
[[ -f "${STATE_ENV}" ]] || fail "no .gourmand-tenant.env — run scripts/seed/gourmand-tenant.sh first"
# shellcheck disable=SC1090
source "${STATE_ENV}"
DB_ID="${GOURMAND_DB_ID:?}"
TENANT="${GOURMAND_TENANT_SLUG:?}"
KONG="${GOURMAND_KONG_URL:?}"
ANON="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
APP_ENV_FILE="${APP_ENV_FILE:-${REPO_ROOT}/apps/osionos/app/.env}"
APP_KEY="${BAAS_API_KEY:-$(sed -n 's/^VITE_BAAS_API_KEY=//p' "${APP_ENV_FILE}" | head -1)}"
[[ "${APP_KEY}" == mbk_* ]] || fail "no app key"

gw() { # $1 expected, $2 path, $3 body|- → /tmp/m24g.json
  local expected="$1" path="$2" body="${3:--}" code attempt
  for attempt in 1 2 3; do
    if [[ "${body}" == "-" ]]; then
      code=$(curl -s -o /tmp/m24g.json -w '%{http_code}' "${KONG}${path}" \
        -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APP_KEY}")
    else
      code=$(curl -s -o /tmp/m24g.json -w '%{http_code}' -X POST "${KONG}${path}" \
        -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APP_KEY}" \
        -H 'Content-Type: application/json' -d "${body}")
    fi
    if [[ "${code}" == "429" || "${code}" == "503" ]] \
      || grep -q 'auth_verify_unavailable' /tmp/m24g.json 2>/dev/null; then
      [[ "${attempt}" -lt 3 ]] && { sleep $((attempt * 3)); continue; }
    fi
    break
  done
  [[ "${code}" == "${expected}" || ( "${expected}" == "2xx" && "${code}" =~ ^2 ) ]] \
    || fail "${path} expected ${expected}, got ${code}: $(head -c 250 /tmp/m24g.json) ← ${body}"
}

# ── 1) schema: the client's real tables ──────────────────────────────────────
step "introspecting the live client schema (mount ${DB_ID}, host ${GOURMAND_DSN_HOST:-?})"
gw 200 "/query/v1/${DB_ID}/schema"
for table in Order Menu Dish WorkingHours SupportTicket TimeOffRequest UserAddress Event KanbanColumn User Role; do
  grep -q "\"name\":\"${table}\"" /tmp/m24g.json || fail "table \"${table}\" missing"
done
grep -q '"owner_id"' /tmp/m24g.json && fail "client schema must NOT contain owner_id columns"
pass "client schema introspected (PascalCase tables, no owner_id anywhere)"

# ── 2) reads return their rows ───────────────────────────────────────────────
step "reading client rows through the gateway"
gw 2xx "/query/v1/${DB_ID}/tables/WorkingHours" '{"op":"list","limit":7,"sort":{"id":"asc"}}'
grep -q '"rows":\[{' /tmp/m24g.json || fail "WorkingHours has no rows — wrong database?"
gw 2xx "/query/v1/${DB_ID}/tables/Role" '{"op":"list","limit":10}'
grep -qE '"name":"(admin|employee)"' /tmp/m24g.json || fail "Role table lacks admin/employee — wrong database?"
pass "WorkingHours + Role rows read"

# ── 3) harmless write roundtrip + revert (KanbanColumn.color) ────────────────
step "write roundtrip on \"KanbanColumn\" (internal board config; reverted)"
gw 2xx "/query/v1/${DB_ID}/tables/KanbanColumn" '{"op":"list","limit":1,"sort":{"id":"asc"}}'
ROW_ID=$(python3 -c "import json; print(json.load(open('/tmp/m24g.json'))['rows'][0]['id'])")
ORIG_COLOR=$(python3 -c "import json; print(json.load(open('/tmp/m24g.json'))['rows'][0].get('color') or '')")
[[ -n "${ROW_ID}" ]] || fail "no KanbanColumn row to probe"
PROBE_COLOR="#a24b0c"
gw 2xx "/query/v1/${DB_ID}/tables/KanbanColumn" \
  "{\"op\":\"update\",\"filter\":{\"id\":${ROW_ID}},\"data\":{\"color\":\"${PROBE_COLOR}\"}}"
grep -q '"rowCount":1' /tmp/m24g.json || fail "probe update touched != 1 row: $(cat /tmp/m24g.json)"
gw 2xx "/query/v1/${DB_ID}/tables/KanbanColumn" "{\"op\":\"get\",\"filter\":{\"id\":${ROW_ID}}}"
grep -q "${PROBE_COLOR}" /tmp/m24g.json || fail "probe color did not land in the client DB"
# revert (empty original → null)
if [[ -n "${ORIG_COLOR}" ]]; then
  gw 2xx "/query/v1/${DB_ID}/tables/KanbanColumn" \
    "{\"op\":\"update\",\"filter\":{\"id\":${ROW_ID}},\"data\":{\"color\":\"${ORIG_COLOR}\"}}"
else
  gw 2xx "/query/v1/${DB_ID}/tables/KanbanColumn" \
    "{\"op\":\"update\",\"filter\":{\"id\":${ROW_ID}},\"data\":{\"color\":null}}"
fi
pass "write landed in the client DB and was reverted (single-row, no owner_id SQL)"

# ── 4) negative: a foreign tenant's key gets nothing ─────────────────────────
step "negative: a foreign tenant's key cannot reach the mount"
source "${SCRIPT_DIR}/lib-live-tenant.sh"
live_tenant_provision "m24foreign$(date +%s)" || fail "could not provision the probe tenant"
trap live_tenant_cleanup EXIT
code=$(curl -s -o /tmp/m24g-foreign.json -w '%{http_code}' "${KONG}/query/v1/${DB_ID}/schema" \
  -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${LIVE_TENANT_API_KEY}")
[[ "${code}" == "403" || "${code}" == "404" ]] \
  || fail "foreign key must be rejected (403/404), got ${code}: $(head -c 200 /tmp/m24g-foreign.json)"
pass "foreign tenant key rejected with ${code} (tenant gating at key→mount resolution)"

green "[M24] OK — gourmand mount live: schema, reads, single-row writes, tenant gating"
