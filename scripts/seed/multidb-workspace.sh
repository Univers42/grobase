#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    multidb-workspace.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/29 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/29 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Plan item W1 (wiki/architecture/multidb-holistic.md): seed ONE dedicated
# workspace with one mount per engine — postgresql cockroachdb mysql mariadb
# mongodb redis sqlite mssql http dynamodb — each holding two static reference
# tables and one churn table (multidb-workspace-gen.py, fixed ids). Every
# object is named mdw_<workspace hex>…, so it never mixes with the demo data of
# seed-live-demo.sh / osionos-extra-engines.sh, and --teardown removes exactly
# those names. No relation contracts and no cross-engine edges: blocked on G12.
#
# The default is --plan: print the ordered actions per engine and touch
# nothing (no docker, no curl). --apply writes, and a live run needs a human
# go. Each engine is gated on its server; a closed gate or a failed step is a
# WARN and the other engines still land.
#
# Usage: bash scripts/seed/multidb-workspace.sh --workspace <uuid> --owner <uuid>
#             [--plan | --apply] [--teardown]
#   --owner  the workspace owner (osionos_workspaces.owner_id); --apply refuses a
#            workspace that is missing or owned by someone else. Rows are stamped
#            with the app key's principal, like the existing seeds, because the
#            bridge reads mounts with that key.
# Env:   BAAS_API_KEY or APP_ENV_FILE (VITE_BAAS_API_KEY), as seed-live-demo.sh;
#        MDW_HTTP_BASE_URL — a public REST endpoint for the http mount (the data
#        plane's SSRF guard refuses in-stack hosts); unset ⇒ http is skipped.
# Engine credentials come from the running containers' env, never from here.
#
# Caveat: idempotence is insert-if-absent plus "409 = already registered",
# which reuses a mount WITHOUT updating its DSN — rotate a credential with
# --teardown --apply first. Gateway inserts read 409 or an "already exists" /
# ConditionalCheckFailed / UNIQUE body as "present"; another error wording is
# reported as a failure (noisy, never silent). Engine gating reads container
# health and the router's /v1/capabilities, so a server that is healthy but
# refuses this tenant only shows up at its register or check step. The sqlite
# file lives in the router's ephemeral /tmp: a router restart empties it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
GEN=(python3 "${SCRIPT_DIR}/multidb-workspace-gen.py")
ENGINES=(postgresql cockroachdb mysql mariadb mongodb redis sqlite mssql http dynamodb)
# WS_ACME / WS_MAIN — the shared workspaces osionos-extra-engines.sh:73-74 writes.
SHARED_WORKSPACES=(ac3e0000-0000-4000-a000-000000000001 0ea96910-277a-49d6-901c-524b147cc009)
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
# Plain HTTP on purpose: DynamoDB Local has no TLS listener and is reachable only
# on the stack's internal network, where both the router and aws-cli talk to it.
DDB_ENDPOINT=http://dynamodb-local:8000

warn() { printf '\033[0;33m[mdw] WARN: %s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[0;31m[mdw] FAIL: %s\033[0m\n' "$*" >&2
  exit 2
}
usage() { sed -n 's/^# \{0,1\}//; /^Usage:/,/^Engine credentials/p' "${BASH_SOURCE[0]}"; }

WS="" OWNER="" APPLY=0 PLAN_FLAG=0 TEARDOWN=0
while (($#)); do
  case "$1" in
  --workspace) WS="${2:-}" && shift ;;
  --owner) OWNER="${2:-}" && shift ;;
  --apply) APPLY=1 ;;
  --plan) PLAN_FLAG=1 ;;
  --teardown) TEARDOWN=1 ;;
  -h | --help) usage && exit 0 ;;
  *) die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done
WS="${WS,,}" OWNER="${OWNER,,}"
[[ "${WS}" =~ ${UUID_RE} ]] || die "--workspace must be a uuid (got '${WS}')"
[[ "${OWNER}" =~ ${UUID_RE} ]] || die "--owner must be a uuid (got '${OWNER}')"
for shared in "${SHARED_WORKSPACES[@]}"; do
  [[ "${WS}" != "${shared}" ]] || die "refused: ${WS} is a shared workspace (WS_ACME/WS_MAIN) — this seeder only writes a dedicated one"
done
((!(APPLY && PLAN_FLAG))) || die "--plan and --apply are exclusive"

DB="mdw_${WS//-/}"
TAG="PLAN" && ((APPLY)) && TAG="APPLY"
TABLES_STD="$("${GEN[@]}" tables-str "")"
TABLES_NS="$("${GEN[@]}" tables-str "${DB}")"
COUNTS="$("${GEN[@]}" counts | paste -sd, - | sed 's/,/, /g')"
echo "mode: ${TAG,,}$( ((TEARDOWN)) && echo ' (teardown)') — workspace ${WS}, owner ${OWNER}, prefix ${DB}"
((APPLY)) || echo "nothing is written; re-run with --apply (a live run needs a human go)"

CUR="" STEP=0 MOUNT_ID="" MONGO_URI="" MS_PASS="" ROUTER_ENGINES="" PG_USER="" PG_PASS=""
line() {
  STEP=$((STEP + 1))
  printf '%s %s %02d %s\n' "${TAG}" "${CUR}" "${STEP}" "$1"
}
# act DESC CMD… — print the step; under --apply run it. A failure ends this
# engine with a WARN; the next engine still runs.
act() {
  local desc="$1"
  shift
  line "${desc}"
  ((APPLY)) || return 0
  "$@" && return 0
  warn "${CUR}: step failed (${desc}) — ${CUR} stops here, other engines continue"
  return 1
}
# gate DESC CMD… — as act, but a closed gate is a skip.
gate() {
  local desc="$1"
  shift
  line "gate: ${desc}"
  ((APPLY)) || return 0
  "$@" && return 0
  warn "${CUR}: gate closed (${desc}) — ${CUR} skipped"
  return 1
}
# need VAR NAME — a credential is set; only its NAME and set/unset are printed.
need() {
  [[ -n "${!1:-}" ]] && return 0
  warn "${CUR}: credential ${2} unset"
  return 1
}
urlenc() { MDW_V="$1" python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["MDW_V"], safe=""))'; }

# ── apply-only plumbing (functions; nothing below runs in plan mode) ─────────
pg() { docker exec -i mini-baas-postgres psql -U "${PG_USER}" -v ON_ERROR_STOP=1 -q "$@"; }
crdb() { docker exec -i mini-baas-cockroach cockroach sql --insecure --host=localhost "$@"; }
# my CONTAINER CLIENT ROOT_PASS_VAR SQL-ARGS… — root client; the password rides env.
my() {
  local c="$1" bin="$2" var="$3"
  shift 3
  MYSQL_PWD="${!var}" docker exec -i -e MYSQL_PWD "${c}" "${bin}" -uroot "$@"
}
ms() { SQLCMDPASSWORD="${MS_PASS}" docker exec -i -e SQLCMDPASSWORD mini-baas-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -N -b "$@"; }
mongo_run() { # $1 script kind [arg] — generated js run by mongosh in a sibling container
  "${GEN[@]}" "$@" >"${MA_TMP}/mongo.js" && chmod 644 "${MA_TMP}/mongo.js" &&
    MDW_MONGO_URI="${MONGO_URI}" docker run --rm --network "$(engine_net mini-baas-mongo mini-baas_mini-baas)" \
      -e MDW_MONGO_URI -v "${MA_TMP}/mongo.js:/seed.js:ro" "$(docker inspect -f '{{.Config.Image}}' mini-baas-mongo)" \
      mongosh --nodb --quiet /seed.js
}
ddb() {
  docker run --rm --network "$(engine_net mini-baas-dynamodb-local mini-baas_mini-baas)" \
    -e AWS_ACCESS_KEY_ID=fake -e AWS_SECRET_ACCESS_KEY=fake -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli dynamodb "$@" --endpoint-url "${DDB_ENDPOINT}"
}
ddb_create() {
  local t
  for t in ${TABLES_NS//,/ }; do
    ddb create-table --table-name "${t}" --billing-mode PAY_PER_REQUEST \
      --attribute-definitions AttributeName=owner_pk,AttributeType=S AttributeName=id,AttributeType=S \
      --key-schema AttributeName=owner_pk,KeyType=HASH AttributeName=id,KeyType=RANGE >/dev/null 2>"${MA_TMP}/ddb.err" ||
      grep -q ResourceInUseException "${MA_TMP}/ddb.err" || return 1
  done
}
ddb_drop() {
  local t
  for t in ${TABLES_NS//,/ }; do
    ddb delete-table --table-name "${t}" >/dev/null 2>"${MA_TMP}/ddb.err" ||
      grep -q ResourceNotFoundException "${MA_TMP}/ddb.err" || return 1
  done
}
has_engine() { [[ " ${ROUTER_ENGINES} " == *" $1 "* ]]; }
register() { ma_register "$1" "${DB}_$1" "$2" && [[ "${MA_REG_ID}" =~ ${UUID_RE} ]] && MOUNT_ID="${MA_REG_ID}"; }
lookup() { MOUNT_ID="$(ma_mount_id "${DB}_${CUR}")" && [[ -z "${MOUNT_ID}" || "${MOUNT_ID}" =~ ${UUID_RE} ]]; }
check_schema() { [[ "$(ma_gw GET "/query/v1/${MOUNT_ID}/schema")" == "200" ]]; }
check_list() { [[ "$(ma_gw POST "/query/v1/${MOUNT_ID}/tables/$1" '{"op":"list","limit":1}')" =~ ^20[01]$ ]]; }
present() { grep -Eqi 'already exists|ConditionalCheckFailed|UNIQUE constraint|duplicate' "${MA_TMP}/gw.json"; }
# gw_rows OP — stdin "table<TAB>json" lines; OP insert (data) or delete (filter id).
gw_rows() {
  local table json code bad=0 body
  while IFS=$'\t' read -r table json; do
    if [[ "$1" == "insert" ]]; then body="{\"op\":\"insert\",\"data\":${json}}"; else body="{\"op\":\"delete\",\"filter\":{\"id\":\"${json}\"}}"; fi
    code="$(ma_gw POST "/query/v1/${MOUNT_ID}/tables/${table}" "${body}")"
    [[ "${code}" =~ ^(200|201|404|409)$ ]] || present || {
      warn "${CUR}: $1 ${table} -> ${code}"
      bad=$((bad + 1))
    }
  done
  ((bad == 0))
}
gw_ddl() { # stdin "table<TAB>ddl-json"
  local table body code
  while IFS=$'\t' read -r table body; do
    code="$(ma_gw POST "/query/v1/${MOUNT_ID}/schema/ddl" "${body}")"
    [[ "${code}" =~ ^(200|201|409)$ ]] || present || grep -qi 'no such table' "${MA_TMP}/gw.json" || return 1
  done
}
sqlite_drop() { "${GEN[@]}" tables-str "" | tr ',' '\n' | sed 's/.*/&\t{"op":"drop_table","table":"&"}/' | gw_ddl; }
assoc() { # $1 label $2 tables-csv — no-op when the row already matches
  pg -d postgres -c "INSERT INTO public.osionos_workspace_databases (workspace_id, db_id, engine, tables, label)
    VALUES ('${WS}', '${MOUNT_ID}', '${CUR}', string_to_array('$2', ','), '$1')
    ON CONFLICT (workspace_id, db_id) DO UPDATE SET engine = EXCLUDED.engine, tables = EXCLUDED.tables,
      label = EXCLUDED.label, updated_at = now()
    WHERE (osionos_workspace_databases.engine, osionos_workspace_databases.tables, osionos_workspace_databases.label)
      IS DISTINCT FROM (EXCLUDED.engine, EXCLUDED.tables, EXCLUDED.label)" >/dev/null
}
unassoc() { pg -d postgres -c "DELETE FROM public.osionos_workspace_databases WHERE workspace_id = '${WS}' AND db_id = '${MOUNT_ID}'" >/dev/null; }

# shellcheck source=multidb-workspace-engines.sh
source "${SCRIPT_DIR}/multidb-workspace-engines.sh"

# ── prelude (apply only resolves; plan prints) ───────────────────────────────
prelude() {
  CUR="prelude"
  act "resolve the app key → tenant + owner principal (tenant-control /v1/keys/verify)" \
    ma_resolve_app "${APP_ENV_FILE:-${REPO_ROOT}/apps/osionos/app/.env}" || die "no stack/app identity — nothing written"
  act "verify workspace ${WS} exists with owner_id ${OWNER} (public.osionos_workspaces)" ws_owned ||
    die "workspace ${WS} is missing or not owned by ${OWNER} — nothing written"
  if ((APPLY)); then
    export MDW_ROW_OWNER="${MA_OWNER}" MDW_ROW_TENANT="${MA_TENANT}"
    ROUTER_ENGINES="$(ma_router_engines)"
    echo "[mdw] router engines: ${ROUTER_ENGINES:-<none reported>}"
  fi
}
ws_owned() {
  PG_USER="$(_lt_env mini-baas-postgres POSTGRES_USER)" PG_USER="${PG_USER:-postgres}"
  PG_PASS="$(_lt_env mini-baas-postgres POSTGRES_PASSWORD)"
  ma_ready mini-baas-postgres &&
    [[ "$(pg -d postgres -tAc "SELECT owner_id FROM public.osionos_workspaces WHERE id = '${WS}'" | tr -d '[:space:]')" == "${OWNER}" ]]
}

if ((APPLY)); then
  # shellcheck source=../lib/lib-live-tenant.sh
  source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"
  # shellcheck source=../lib/lib-mount-admin.sh
  source "${SCRIPT_DIR}/../lib/lib-mount-admin.sh"
  # shellcheck source=../lib/lib-netseg.sh
  source "${SCRIPT_DIR}/../lib/lib-netseg.sh"
  MA_TMP="$(mktemp -d)"
  trap 'rm -rf "${MA_TMP}"' EXIT
fi
prelude
for CUR in "${ENGINES[@]}"; do
  STEP=0 MOUNT_ID=""
  if ((TEARDOWN)); then
    teardown_gate && teardown_engine || true
  else
    "seed_${CUR}" || true
  fi
done
echo "[mdw] done — ${TAG,,}$( ((TEARDOWN)) && echo ' teardown'), ${#ENGINES[@]} engines (WARN lines above name any skipped)"
