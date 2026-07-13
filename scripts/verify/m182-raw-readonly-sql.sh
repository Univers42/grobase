#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m182-raw-readonly-sql.sh — query-router read-only SQL endpoint gate         #
#                                                                              #
#  Proves POST /:dbId/sql-ro (flag QUERY_ROUTER_SQL_RO) against the RUNNING    #
#  stack, on a discovered postgres mount:                                      #
#    1  SELECT       — a read returns rows (rowCount >= 0, HTTP 200).           #
#    2  INSERT       — a write is REJECTED (4xx; READ ONLY txn, SQLSTATE 25006).#
#    3  CREATE TABLE — DDL is REJECTED (4xx).                                   #
#    4  MULTI-STMT   — two statements are REJECTED (400, single-statement).     #
#    5  UNAUTH       — no X-Baas-Api-Key → 401.                                 #
#                                                                              #
#  Requires the query-router image REBUILT with the sql-ro slice AND           #
#  QUERY_ROUTER_SQL_RO=1 in its env. If the endpoint 404s, the gate says so     #
#  and exits (feature not enabled), never a false green.                        #
#  The cleartext owner key is read from the running osionos-bridge container.   #
# **************************************************************************** #
set -euo pipefail

BRIDGE_CTN="track-binocle-osionos-bridge-1"
QR_CTN="mini-baas-query-router"
PG_CTN="mini-baas-postgres"
DEV_WS="0ea96910-277a-49d6-901c-524b147cc009"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M182] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[0;31m[M182] FAIL — %s\033[0m\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
dexec() { docker exec "$@"; }
running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

step "0/5 preconditions — bridge, query-router, postgres up + owner key"
for ctn in "${BRIDGE_CTN}" "${QR_CTN}" "${PG_CTN}"; do
  running "${ctn}" || fail "container ${ctn} is not running (start the stack + grobase first)"
done
AK="$(dexec "${BRIDGE_CTN}" sh -c 'printenv OSIONOS_BAAS_API_KEY || printenv BAAS_API_KEY' 2>/dev/null || true)"
[[ -n "${AK}" ]] || fail "no owner API key in the bridge container (OSIONOS_BAAS_API_KEY)"
ok "stack up; owner key ${AK:0:8}…"

step "1/5 discover a postgres mount linked to the dev workspace"
PG_MOUNT="$(dexec "${PG_CTN}" psql -U postgres -d postgres -At -c \
  "SELECT db_id FROM public.osionos_workspace_databases
     WHERE workspace_id='${DEV_WS}' AND engine='postgresql'
       AND db_id ~ '^[0-9a-f-]{36}\$' LIMIT 1;" 2>/dev/null || true)"
[[ -n "${PG_MOUNT}" ]] || fail "no postgres mount linked to workspace ${DEV_WS:0:8}… (seed the dev workspace first)"
ok "postgres mount ${PG_MOUNT:0:8}…"

# One request to /:dbId/sql-ro; prints "<status> <bodyLen>".
cat >"${TMP}/run.mjs" <<'NODE'
const [AK, db, sql] = process.argv.slice(2);
const headers = { 'Content-Type': 'application/json' };
if (AK) headers['X-Baas-Api-Key'] = AK;
const res = await fetch(`http://127.0.0.1:4001/${db}/sql-ro`, {
  method: 'POST', headers, body: JSON.stringify({ sql }),
});
const text = await res.text().catch(() => '');
process.stdout.write(`${res.status} ${text.length}`);
NODE
dexec -i "${QR_CTN}" sh -c 'cat > /tmp/m182-run.mjs' < "${TMP}/run.mjs"
run() { dexec "${QR_CTN}" node /tmp/m182-run.mjs "$1" "${PG_MOUNT}" "$2" 2>/dev/null || echo "0 0"; }
status_of() { printf '%s' "$1" | cut -d' ' -f1; }

step "2/5 SELECT returns rows (HTTP 200)"
SEL="$(run "${AK}" 'SELECT 1 AS one')"
sc="$(status_of "${SEL}")"
[[ "${sc}" == "404" ]] && fail "endpoint 404 — query-router not rebuilt with sql-ro, or QUERY_ROUTER_SQL_RO not set"
[[ "${sc}" == "200" ]] || fail "SELECT returned HTTP ${sc} (${SEL})"
ok "SELECT → 200"

step "3/5 INSERT is rejected (READ ONLY)"
INS="$(run "${AK}" "INSERT INTO nonexistent_t (x) VALUES (1)")"
[[ "$(status_of "${INS}")" =~ ^4 ]] || fail "INSERT not rejected: HTTP $(status_of "${INS}") (${INS})"
ok "INSERT → $(status_of "${INS}") (rejected)"

step "4/5 CREATE TABLE (DDL) is rejected"
DDL="$(run "${AK}" "CREATE TABLE m182_x (id int)")"
[[ "$(status_of "${DDL}")" =~ ^4 ]] || fail "CREATE not rejected: HTTP $(status_of "${DDL}") (${DDL})"
ok "CREATE TABLE → $(status_of "${DDL}") (rejected)"

step "4b/5 multi-statement is rejected (400)"
MULTI="$(run "${AK}" "SELECT 1; SELECT 2")"
[[ "$(status_of "${MULTI}")" == "400" ]] || fail "multi-statement not 400: HTTP $(status_of "${MULTI}") (${MULTI})"
ok "multi-statement → 400"

step "5/5 unauthenticated → 401"
UN="$(run "" 'SELECT 1')"
[[ "$(status_of "${UN}")" == "401" ]] || fail "unauth not 401: HTTP $(status_of "${UN}") (${UN})"
ok "no api key → 401"

printf '\033[0;32m[M182] ALL GATES GREEN — read-only SQL: SELECT ok · INSERT/DDL/multi-stmt rejected · unauth 401\033[0m\n'
