#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m182-raw-readonly-sql.sh — query-router read-only SQL endpoint gate         #
#                                                                              #
#  Proves POST /:dbId/sql-ro (flag QUERY_ROUTER_SQL_RO) against the RUNNING    #
#  stack, on a discovered tenant_owned postgres mount the owner key owns:     #
#    1  SELECT       — a read returns rows (rowCount >= 0, HTTP 200).           #
#    2  INSERT       — a write is REJECTED (4xx; READ ONLY txn, SQLSTATE 25006).#
#    3  CREATE TABLE — DDL is REJECTED (4xx).                                   #
#    4  MULTI-STMT   — two statements are REJECTED (400, single-statement).     #
#    5  UNAUTH       — no X-Baas-Api-Key → 401.                                 #
#    6  REFUSALS     — raw SQL runs OUTSIDE the Rust pool, so it must never    #
#                      reach a mount it cannot scope. Each must 404 with an   #
#                      error body (statusCode·error·message) IDENTICAL to an  #
#                      unknown dbId's (no existence leak):                    #
#       6a unknown dbId (the baseline 404)                                     #
#       6b a FOREIGN tenant's mount                                            #
#       6c a static DATA_PLANE_MOUNTS dbId (matched by dbId alone, no owner)  #
#       6d an own read_scoped mount (migration 070)                            #
#       6e an own mount owner-scoped per request (isolation ≠ tenant_owned)   #
#     A refusal leg with no such mount on this stack is printed as SKIP and    #
#     listed in the final line — never counted as proven.                      #
#                                                                              #
#  Requires the query-router image REBUILT with the sql-ro slice AND           #
#  QUERY_ROUTER_SQL_RO=1 in its env. If the endpoint 404s on the owned mount,  #
#  the gate says so and exits (feature not enabled), never a false green —     #
#  every refusal leg runs only AFTER that 200, since flag-OFF is also a 404.   #
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
fail() {
  printf '\033[0;31m[M182] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
SKIPPED=""
skip_leg() {
  printf '\033[0;33m  - SKIP %s — %s\033[0m\n' "$1" "$2"
  SKIPPED="${SKIPPED} $1"
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
dexec() { docker exec "$@"; }
running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
psql_q() { dexec "${PG_CTN}" psql -U postgres -d postgres -At -c "$1" 2>/dev/null || true; }

step "0/6 preconditions — bridge, query-router, postgres up + owner key"
for ctn in "${BRIDGE_CTN}" "${QR_CTN}" "${PG_CTN}"; do
  running "${ctn}" || fail "container ${ctn} is not running (start the stack + grobase first)"
done
AK="$(dexec "${BRIDGE_CTN}" sh -c 'printenv OSIONOS_BAAS_API_KEY || printenv BAAS_API_KEY' 2>/dev/null || true)"
[[ -n "${AK}" ]] || fail "no owner API key in the bridge container (OSIONOS_BAAS_API_KEY)"
ok "stack up; owner key ${AK:0:8}…"

step "1/6 discover a tenant_owned postgres mount linked to the dev workspace"
IFS='|' read -r PG_MOUNT OWN_TENANT <<<"$(psql_q \
  "SELECT w.db_id || '|' || td.tenant_id
     FROM public.osionos_workspace_databases w
     JOIN public.tenant_databases td ON td.id::text = w.db_id
    WHERE w.workspace_id='${DEV_WS}' AND w.engine='postgresql'
      AND w.db_id ~ '^[0-9a-f-]{36}\$'
      AND td.isolation='tenant_owned' AND NOT td.read_scoped LIMIT 1;")" || true
[[ -n "${PG_MOUNT:-}" ]] ||
  fail "no tenant_owned, non-read_scoped postgres mount linked to workspace ${DEV_WS:0:8}… (sql-ro serves only those; seed the dev workspace first)"
[[ "${OWN_TENANT:-}" =~ ^[A-Za-z0-9_-]+$ ]] || fail "mount ${PG_MOUNT:0:8}… has an unexpected tenant id '${OWN_TENANT:-}'"
ok "postgres mount ${PG_MOUNT:0:8}… (tenant_owned) of tenant ${OWN_TENANT:0:8}…"

# One request to /:dbId/sql-ro; prints "<status> <bodyLen> <sha>". The sha covers
# only the error envelope's stable fields (statusCode · error · message) — the
# global filter also stamps a per-request requestId + timestamp.
cat >"${TMP}/run.mjs" <<'NODE'
import { createHash } from 'node:crypto';
const [AK, db, sql] = process.argv.slice(2);
const headers = { 'Content-Type': 'application/json' };
if (AK) headers['X-Baas-Api-Key'] = AK;
const res = await fetch(`http://127.0.0.1:4001/${db}/sql-ro`, {
  method: 'POST', headers, body: JSON.stringify({ sql }),
});
const text = await res.text().catch(() => '');
let stable = text;
try {
  const { statusCode, error, message } = JSON.parse(text);
  stable = JSON.stringify({ statusCode, error, message });
} catch {}
const sha = createHash('sha256').update(stable).digest('hex').slice(0, 16);
process.stdout.write(`${res.status} ${stable.length} ${sha}`);
NODE
dexec -i "${QR_CTN}" sh -c 'cat > /tmp/m182-run.mjs' <"${TMP}/run.mjs"
run_on() { dexec "${QR_CTN}" node /tmp/m182-run.mjs "$1" "$2" "$3" 2>/dev/null || echo "0 0 -"; }
run() { run_on "$1" "${PG_MOUNT}" "$2"; }
status_of() { printf '%s' "$1" | cut -d' ' -f1; }
body_of() { printf '%s' "$1" | cut -d' ' -f2-; }

step "2/6 SELECT returns rows (HTTP 200)"
SEL="$(run "${AK}" 'SELECT 1 AS one')"
sc="$(status_of "${SEL}")"
[[ "${sc}" == "404" ]] && fail "endpoint 404 on the owned tenant_owned mount — query-router not rebuilt with sql-ro, or QUERY_ROUTER_SQL_RO not set"
[[ "${sc}" == "200" ]] || fail "SELECT returned HTTP ${sc} (${SEL})"
ok "SELECT → 200"

step "3/6 INSERT is rejected (READ ONLY)"
INS="$(run "${AK}" "INSERT INTO nonexistent_t (x) VALUES (1)")"
[[ "$(status_of "${INS}")" =~ ^4 ]] || fail "INSERT not rejected: HTTP $(status_of "${INS}") (${INS})"
ok "INSERT → $(status_of "${INS}") (rejected)"

step "4/6 CREATE TABLE (DDL) is rejected"
DDL="$(run "${AK}" "CREATE TABLE m182_x (id int)")"
[[ "$(status_of "${DDL}")" =~ ^4 ]] || fail "CREATE not rejected: HTTP $(status_of "${DDL}") (${DDL})"
ok "CREATE TABLE → $(status_of "${DDL}") (rejected)"

step "4b/6 multi-statement is rejected (400)"
MULTI="$(run "${AK}" "SELECT 1; SELECT 2")"
[[ "$(status_of "${MULTI}")" == "400" ]] || fail "multi-statement not 400: HTTP $(status_of "${MULTI}") (${MULTI})"
ok "multi-statement → 400"

step "5/6 unauthenticated → 401"
UN="$(run "" 'SELECT 1')"
[[ "$(status_of "${UN}")" == "401" ]] || fail "unauth not 401: HTTP $(status_of "${UN}") (${UN})"
ok "no api key → 401"

step "6/6 refusals — each 404s with the unknown-dbId body (no existence leak)"
UNKNOWN_DB="$(dexec "${QR_CTN}" node -e 'process.stdout.write(require("node:crypto").randomUUID())')"
MISS="$(run_on "${AK}" "${UNKNOWN_DB}" 'SELECT 1')"
[[ "$(status_of "${MISS}")" == "404" ]] || fail "6a unknown dbId not 404: HTTP $(status_of "${MISS}") (${MISS})"
ok "6a unknown dbId → 404 (baseline body $(body_of "${MISS}"))"

# refuse <leg> <label> <dbId>: the owner key's SELECT on <dbId> must be the baseline 404.
refuse() {
  local out
  out="$(run_on "${AK}" "$3" 'SELECT 1')"
  [[ "$(status_of "${out}")" == "404" ]] || fail "$1 $2 not refused: HTTP $(status_of "${out}") (${out})"
  [[ "$(body_of "${out}")" == "$(body_of "${MISS}")" ]] ||
    fail "$1 $2 404 body differs from an unknown dbId's — it leaks existence (${out} vs ${MISS})"
  ok "$1 $2 → 404, body identical to an unknown dbId"
}

IFS='|' read -r FOREIGN_DB FOREIGN_ISO <<<"$(psql_q \
  "SELECT id::text || '|' || isolation FROM public.tenant_databases
    WHERE tenant_id <> '${OWN_TENANT}' AND engine='postgresql'
    ORDER BY (isolation='tenant_owned' AND NOT read_scoped) DESC LIMIT 1;")" || true
if [[ -n "${FOREIGN_DB:-}" ]]; then
  refuse 6b "foreign tenant mount ${FOREIGN_DB:0:8}… (${FOREIGN_ISO})" "${FOREIGN_DB}"
else
  skip_leg 6b "no postgres mount of another tenant on this stack"
fi

STATIC_DB="$(dexec "${QR_CTN}" node -e '
  try {
    const m = JSON.parse(process.env.DATA_PLANE_MOUNTS || "{}");
    process.stdout.write(Object.keys(m).find((k) => /^[0-9a-f-]{36}$/.test(k)) || "");
  } catch {}' 2>/dev/null || true)"
if [[ -n "${STATIC_DB}" ]]; then
  refuse 6c "static DATA_PLANE_MOUNTS dbId ${STATIC_DB:0:8}…" "${STATIC_DB}"
else
  skip_leg 6c "query-router has no UUID-keyed DATA_PLANE_MOUNTS entry"
fi

SCOPED_DB="$(psql_q "SELECT id::text FROM public.tenant_databases
  WHERE tenant_id='${OWN_TENANT}' AND engine='postgresql' AND read_scoped LIMIT 1;")"
if [[ -n "${SCOPED_DB}" ]]; then
  refuse 6d "own read_scoped mount ${SCOPED_DB:0:8}…" "${SCOPED_DB}"
else
  skip_leg 6d "tenant ${OWN_TENANT:0:8}… has no read_scoped postgres mount"
fi

IFS='|' read -r OWNED_DB OWNED_ISO <<<"$(psql_q \
  "SELECT id::text || '|' || isolation FROM public.tenant_databases
    WHERE tenant_id='${OWN_TENANT}' AND engine='postgresql'
      AND NOT read_scoped AND isolation <> 'tenant_owned' LIMIT 1;")" || true
if [[ -n "${OWNED_DB:-}" ]]; then
  refuse 6e "own owner-scoped mount ${OWNED_DB:0:8}… (${OWNED_ISO})" "${OWNED_DB}"
else
  skip_leg 6e "tenant ${OWN_TENANT:0:8}… has no postgres mount with isolation ≠ tenant_owned"
fi

if [[ -n "${SKIPPED}" ]]; then
  printf '\033[0;33m[M182] GREEN WITH SKIPS — refusal legs NOT proven on this stack:%s\033[0m\n' "${SKIPPED}"
  exit 0
fi
printf '\033[0;32m[M182] ALL GATES GREEN — read-only SQL: SELECT ok · INSERT/DDL/multi-stmt rejected · unauth 401 · foreign/static/read_scoped/owner-scoped mounts 404 like an unknown dbId\033[0m\n'
