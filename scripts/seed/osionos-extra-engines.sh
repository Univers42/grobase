#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    osionos-extra-engines.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/25 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/25 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Adds SQLite, MSSQL and DynamoDB as LIVE mounts to the osionos multi-engine
# graph, owned by the SAME app key as the existing pg/mysql/mongo commerce demo
# (seed-live-demo.sh) so the existing graph + access flow picks them up with no
# client change. Deterministic, owner-stamped, idempotent (re-runs converge).
#
#   sqlite 'restaurant'  → restaurant, menu, dish, restaurant_order, order_item,
#                          working_hours — created + loaded THROUGH the gateway
#                          (the file lives inside the data-plane container; there
#                          is no sibling tool to reach it, so DDL+insert over
#                          /query/v1 is the only honest path). Modest row counts.
#                          CAVEAT: the sqlite file lives in the router's ephemeral
#                          /tmp (the distroless `nonroot` user's only writable
#                          dir), so a `data-plane-router` container RESTART wipes
#                          it — re-run this script to restore. mssql/dynamodb data
#                          persists (external servers). For durable sqlite, mount
#                          a volume at the router's sqlite dir in compose.
#   mssql  'finance'     → invoices, invoice_lines, payments, gl_accounts,
#                          cost_centers — created + bulk-loaded via sqlcmd
#                          (direct, like seed-live-demo loads pg/mysql).
#   dynamodb 'iot'       → devices, device_events, alerts — tables via the AWS
#                          API (aws-cli → dynamodb-local), items batch-written
#                          with owner_pk = the owner principal (the partition key
#                          the adapter scopes on).
#
# Then it inserts INTERLEAVED cross-engine edges into commerce.public.edges
# (invoice→order, payment→customer, restaurant_order→customer, device→product)
# referencing existing commerce ids, and associates each new mount with the two
# shared workspaces (Acme Operations + dev.pro.photo main) so members see them.
#
# Each engine is gated on its server being up: a down server or an engine CHECK
# 4xx ⇒ skip-clean + WARN, never a hard fail (the other engines still land).
#
# Usage:  bash scripts/seed/osionos-extra-engines.sh
# Env:    BAAS_API_KEY (defaults to VITE_BAAS_API_KEY from the app .env),
#         APP_ENV_FILE, SKIP_SQLITE=1 (force-skip sqlite)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/service-auth.sh
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"
BAAS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BAAS_DIR}/../../.." && pwd)"
cd "${BAAS_DIR}"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step() { cyan "[xeng] $*"; }
pass() { green "[xeng] PASS: $*"; }
warn() { yellow "[xeng] WARN: $*" >&2; }
fail() {
  red "[xeng] FAIL: $*"
  exit 1
}

# Existing commerce mount (the pg dbId) — the edges 'to' node ids point here.
COMMERCE_DB_ID="59939f19-7e8d-4876-a57f-61b3e7bb37be"
WS_ACME="ac3e0000-0000-4000-a000-000000000001"
WS_MAIN="0ea96910-277a-49d6-901c-524b147cc009"
APP_ENV_FILE="${APP_ENV_FILE:-${REPO_ROOT}/apps/osionos/app/.env}"

container_up() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }
pg() { docker exec -i mini-baas-postgres psql -U postgres "$@"; }

# ── 1) stack endpoints + the app's identity (mirrors seed-live-demo) ────────
step "resolving the running stack + app identity"
KONG_PORT="$(_lt_host_port mini-baas-kong 8000/tcp)"
TC_PORT="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
[[ -n "${KONG_PORT}" && -n "${TC_PORT}" ]] || fail "mini-baas stack not up (kong/tenant-control unmapped)"
KONG_URL="http://127.0.0.1:${KONG_PORT}"
TC_URL="http://127.0.0.1:${TC_PORT}"
export SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
ANON_KEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "control-plane credentials not found"

APP_KEY="${BAAS_API_KEY:-$(sed -n 's/^VITE_BAAS_API_KEY=//p' "${APP_ENV_FILE}" 2>/dev/null | head -1)}"
[[ "${APP_KEY}" == mbk_* ]] || fail "no tenant API key — set BAAS_API_KEY or VITE_BAAS_API_KEY in ${APP_ENV_FILE}"
vbody="{\"key\":\"${APP_KEY}\"}"
svc_auth POST /v1/keys/verify "${vbody}"
verify=$(curl -fsS -X POST "${TC_URL}/v1/keys/verify" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${vbody}") ||
  fail "tenant-control /v1/keys/verify unreachable"
echo "${verify}" | grep -q '"valid":true' || fail "the app key is not valid: ${verify}"
TENANT="$(echo "${verify}" | _lt_json_field tenant_id)"
KEY_ID="$(echo "${verify}" | _lt_json_field key_id)"
[[ -n "${TENANT}" && -n "${KEY_ID}" ]] || fail "verify response missing tenant_id/key_id"
OWNER="api-key:${KEY_ID}"
pass "app key → tenant '${TENANT}', owner principal '${OWNER}'"

# ── 2) helpers: mount registration + gateway calls (apikey + X-Baas-Api-Key) ─
# register_mount sets REG_CODE + REG_ID globals (survives a $() subshell loss).
register_mount() { # $1 engine, $2 name, $3 dsn
  local body="{\"engine\":\"$1\",\"name\":\"$2\",\"connection_string\":\"$3\"}"
  REG_ID=""
  REG_CODE=$(curl -s -o /tmp/xeng-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" \
    -H 'Content-Type: application/json' -d "${body}")
  if [[ "${REG_CODE}" == "201" ]]; then
    REG_ID="$(_lt_json_field id </tmp/xeng-mount.json)"
  elif [[ "${REG_CODE}" == "409" ]]; then
    REG_ID="$(curl -fsS "${KONG_URL}/admin/v1/databases" \
      -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" |
      MNT="$2" python3 -c 'import json,sys,os; print(next((r["id"] for r in json.load(sys.stdin) if r.get("name")==os.environ["MNT"]),""))')"
  fi
}

# gw — a gateway call with the APP's own key (the osionos graph path).
gw() { curl -s -o /tmp/xeng-gw.json -w '%{http_code}' "$@" \
  -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${APP_KEY}"; }

# deregister_mount — HMAC-signed admin delete by id (Kong strips the path, so the
# signature binds the bare /databases/<id>). Best-effort: a 200 or 404 is fine.
# Needed because re-registering an existing name returns 409 WITHOUT updating the
# DSN — so a changed connection_string only takes effect after a delete first.
deregister_mount() { # $1 mount id
  [[ -n "$1" ]] || return 0
  svc_auth DELETE "/databases/$1" ""
  curl -s -o /dev/null -X DELETE "${KONG_URL}/admin/v1/databases/$1" \
    -H "apikey: ${SERVICE_KEY}" "${SVC_AUTH[@]}" -H "X-Tenant-Id: ${TENANT}" || true
}

# mount_id_by_name — current id of a tenant mount (empty if none).
mount_id_by_name() { # $1 name
  curl -fsS "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" 2>/dev/null |
    MNT="$1" python3 -c 'import json,sys,os; print(next((r["id"] for r in json.load(sys.stdin) if r.get("name")==os.environ["MNT"]),""))' 2>/dev/null
}

# engine_check — does the mount answer a schema introspect (engine truly wired)?
engine_check() { # $1 dbId -> echoes http code
  gw "${KONG_URL}/query/v1/$1/schema"
}

# router_pools — the engines the RUNNING router image was COMPILED with (its
# `/v1/capabilities` engine list — the authoritative cfg-gated set; the sibling
# `query_execution` string is a stale hardcoded literal, not used). A stale GHCR
# pull-fallback image omits sqlite/mssql/dynamodb here, so a skip is explained
# ("engine not built into the running router image — rebuild + recreate").
router_pools() {
  local p
  p="$(_lt_host_port mini-baas-data-plane-router-rust 4011/tcp)"
  [[ -n "${p}" ]] || { echo ""; return; }
  curl -s "http://127.0.0.1:${p}/v1/capabilities" 2>/dev/null |
    python3 -c 'import json,sys
try: print(" ".join(e.get("engine","") for e in json.load(sys.stdin).get("engines",[])))
except Exception: print("")' 2>/dev/null
}
ROUTER_POOLS="$(router_pools)"
[[ -n "${ROUTER_POOLS}" ]] && cyan "router engines: ${ROUTER_POOLS}"

# ── deterministic PRNG (seed 42) shared by every generator ──────────────────
# A tiny LCG so a re-run produces byte-identical rows. Implemented in the python
# generators inline; bash only drives row counts.

SQLITE_DB_ID=""
MSSQL_DB_ID=""
DYNAMO_DB_ID=""

# ────────────────────────────────────────────────────────────────────────────
# SQLITE 'restaurant' — created + loaded through the gateway (file is in-container)
# ────────────────────────────────────────────────────────────────────────────
seed_sqlite() {
  if [[ "${SKIP_SQLITE:-0}" == "1" ]]; then
    warn "sqlite: SKIP_SQLITE=1 — skipped by request"
    return 0
  fi
  step "sqlite: registering mount 'osionos-restaurant' (file-backed, in data-plane container)"
  # /tmp is the only path the distroless `nonroot` router can write (matches the
  # m27 conformance gate's `sqlite:///tmp/...`); /var/lib is root-owned → EACCES.
  local SQLITE_DSN="sqlite:///tmp/osionos-restaurant.db"
  register_mount sqlite osionos-restaurant "${SQLITE_DSN}"
  if [[ "${REG_CODE}" != "201" && "${REG_CODE}" != "409" ]]; then
    warn "sqlite: mount register failed (${REG_CODE}): $(head -c 200 /tmp/xeng-mount.json) — skipping sqlite"
    return 0
  fi
  SQLITE_DB_ID="${REG_ID}"
  [[ -n "${SQLITE_DB_ID}" ]] || { warn "sqlite: no mount id — skipping"; SQLITE_DB_ID=""; return 0; }

  local code
  code=$(engine_check "${SQLITE_DB_ID}")
  if [[ "${code}" != "200" ]]; then
    if [[ "${ROUTER_POOLS}" != *sqlite* ]]; then
      warn "sqlite: not in the running router's pools (${ROUTER_POOLS:-?}) — rebuild the router image (it ships only the GHCR-pinned pools) and recreate the container, then re-run. Skipping sqlite."
      SQLITE_DB_ID=""
      return 0
    fi
    # A pre-existing mount kept a stale (e.g. /var/lib, unwritable) DSN — 409
    # never updates it. Deregister + re-register once so the /tmp DSN takes hold.
    cyan "sqlite: engine CHECK ${code} on existing mount — re-registering with the writable DSN"
    deregister_mount "${SQLITE_DB_ID}"
    register_mount sqlite osionos-restaurant "${SQLITE_DSN}"
    SQLITE_DB_ID="${REG_ID}"
    code=$(engine_check "${SQLITE_DB_ID}")
    if [[ "${code}" != "200" ]]; then
      warn "sqlite: engine CHECK still ${code} after re-register: $(head -c 200 /tmp/xeng-gw.json) — skipping sqlite"
      SQLITE_DB_ID=""
      return 0
    fi
  fi
  cyan "sqlite mount = ${SQLITE_DB_ID} (engine wired)"

  step "sqlite: create tables via /query/v1/${SQLITE_DB_ID}/schema/ddl"
  # create_table is idempotent here: 200/201 = created, 409 or a 400 whose body
  # says "already exists" = the table is already there (a re-run), both fine.
  ddl() { # $1 table, $2 columns-json, $3 pk-json
    code=$(gw -X POST "${KONG_URL}/query/v1/${SQLITE_DB_ID}/schema/ddl" \
      -H 'Content-Type: application/json' \
      -d "{\"op\":\"create_table\",\"table\":\"$1\",\"columns\":$2,\"primary_key\":$3}")
    [[ "${code}" =~ ^(200|201|409)$ ]] && return 0
    grep -q "already exists" /tmp/xeng-gw.json && return 0
    warn "sqlite: create_table $1 -> ${code}: $(head -c 200 /tmp/xeng-gw.json)"
    return 1
  }
  local I='{"name":"id","normalized_type":"integer","nullable":false}'
  local T='{"name":"%s","normalized_type":"text","nullable":true}'
  ddl restaurant      "[$I,$(printf "$T" name),$(printf "$T" cuisine),$(printf "$T" city)]" '["id"]' || { SQLITE_DB_ID=""; return 0; }
  ddl menu            "[$I,{\"name\":\"restaurant_id\",\"normalized_type\":\"integer\",\"nullable\":true},$(printf "$T" name)]" '["id"]' || { SQLITE_DB_ID=""; return 0; }
  ddl dish            "[$I,{\"name\":\"menu_id\",\"normalized_type\":\"integer\",\"nullable\":true},$(printf "$T" name),{\"name\":\"price_cents\",\"normalized_type\":\"integer\",\"nullable\":true}]" '["id"]' || { SQLITE_DB_ID=""; return 0; }
  ddl restaurant_order "[$I,{\"name\":\"restaurant_id\",\"normalized_type\":\"integer\",\"nullable\":true},{\"name\":\"customer_ref\",\"normalized_type\":\"integer\",\"nullable\":true},$(printf "$T" status),{\"name\":\"total_cents\",\"normalized_type\":\"integer\",\"nullable\":true}]" '["id"]' || { SQLITE_DB_ID=""; return 0; }
  ddl order_item      "[$I,{\"name\":\"order_id\",\"normalized_type\":\"integer\",\"nullable\":true},{\"name\":\"dish_id\",\"normalized_type\":\"integer\",\"nullable\":true},{\"name\":\"qty\",\"normalized_type\":\"integer\",\"nullable\":true}]" '["id"]' || { SQLITE_DB_ID=""; return 0; }
  ddl working_hours   "[$I,{\"name\":\"restaurant_id\",\"normalized_type\":\"integer\",\"nullable\":true},{\"name\":\"weekday\",\"normalized_type\":\"integer\",\"nullable\":true},$(printf "$T" opens),$(printf "$T" closes)]" '["id"]' || { SQLITE_DB_ID=""; return 0; }

  step "sqlite: loading deterministic rows via gateway op=insert (paced, idempotent)"
  # The generator emits one JSON object per line; each is a single-row insert.
  # The gateway caps the app key at ~300 req/min, so a 429 backs off on its
  # RateLimit-Reset (seconds) and retries; transient 502/503 (a busy upstream /
  # tenant-control blip) get a short bounded retry too. 409 (already present) is
  # fine → an idempotent re-run converges to the count. A row that still fails
  # after retries is logged and SKIPPED (the load keeps going, not aborts).
  SQLITE_OWNER="${OWNER}" python3 "${SCRIPT_DIR}/extra-engines-gen.py" restaurant |
    while IFS=$'\t' read -r table json; do
      attempt=0
      while :; do
        code=$(curl -s -o /tmp/xeng-gw.json -D /tmp/xeng-hdr.txt -w '%{http_code}' \
          -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${APP_KEY}" \
          -X POST "${KONG_URL}/query/v1/${SQLITE_DB_ID}/tables/${table}" \
          -H 'Content-Type: application/json' -d "{\"op\":\"insert\",\"data\":${json}}")
        if [[ "${code}" == "429" ]]; then
          reset="$(sed -n 's/[Rr]ate[Ll]imit-[Rr]eset:[[:space:]]*\([0-9]*\).*/\1/p' /tmp/xeng-hdr.txt | head -1)"
          sleep "$(( ${reset:-5} > 0 ? ${reset:-5} : 5 ))"
          continue
        fi
        if [[ "${code}" =~ ^(502|503)$ ]] && (( attempt < 5 )); then
          attempt=$((attempt + 1))
          sleep 3
          continue
        fi
        break
      done
      [[ "${code}" =~ ^(200|201|409)$ ]] ||
        warn "sqlite: insert into ${table} -> ${code}: $(head -c 120 /tmp/xeng-gw.json) (skipped this row)"
    done
  pass "sqlite restaurant loaded (mount ${SQLITE_DB_ID})"
}

# ────────────────────────────────────────────────────────────────────────────
# MSSQL 'finance' — created + bulk-loaded via sqlcmd, then registered
# ────────────────────────────────────────────────────────────────────────────
seed_mssql() {
  if ! container_up mini-baas-mssql; then
    warn "mssql: mini-baas-mssql not running — skipping mssql"
    return 0
  fi
  local SA_PASS
  SA_PASS="$(_lt_env mini-baas-mssql MSSQL_SA_PASSWORD)"; SA_PASS="${SA_PASS:-Mssql_Strong!Pass1}"
  local sqlcmd=(docker exec -i mini-baas-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${SA_PASS}" -C -N -b)

  step "mssql: waiting for SQL Server to accept connections"
  local ok=0
  for _ in $(seq 1 30); do
    if "${sqlcmd[@]}" -Q "SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
  done
  [[ "${ok}" == "1" ]] || { warn "mssql: server not accepting connections after 60s — skipping"; return 0; }

  step "mssql: ensure 'finance' database + schema (idempotent)"
  "${sqlcmd[@]}" -Q "IF DB_ID('finance') IS NULL CREATE DATABASE finance;" >/dev/null 2>&1 ||
    { warn "mssql: CREATE DATABASE finance failed — skipping"; return 0; }
  # Schema + deterministic bulk rows generated as one T-SQL script.
  if ! MSSQL_OWNER="${OWNER}" python3 "${SCRIPT_DIR}/extra-engines-gen.py" finance |
    "${sqlcmd[@]}" -d finance >/tmp/xeng-mssql.log 2>&1; then
    warn "mssql: schema/load script failed: $(tail -3 /tmp/xeng-mssql.log)"
    return 0
  fi

  step "mssql: registering mount 'osionos-finance'"
  register_mount mssql osionos-finance "mssql://sa:${SA_PASS}@mssql:1433/finance"
  if [[ "${REG_CODE}" != "201" && "${REG_CODE}" != "409" ]]; then
    warn "mssql: mount register failed (${REG_CODE}): $(head -c 200 /tmp/xeng-mount.json) — skipping"
    return 0
  fi
  MSSQL_DB_ID="${REG_ID}"
  [[ -n "${MSSQL_DB_ID}" ]] || { warn "mssql: no mount id — skipping"; MSSQL_DB_ID=""; return 0; }

  local code
  code=$(engine_check "${MSSQL_DB_ID}")
  if [[ "${code}" != "200" ]]; then
    if [[ "${ROUTER_POOLS}" != *mssql* ]]; then
      warn "mssql: not in the running router's pools (${ROUTER_POOLS:-?}) — rebuild + recreate the router, then re-run. Data IS loaded in finance; mount kept; edges/assoc skipped."
    else
      warn "mssql: engine CHECK (schema) returned ${code}: $(head -c 200 /tmp/xeng-gw.json) — mount kept but edges/assoc skipped"
    fi
    MSSQL_DB_ID=""
    return 0
  fi
  pass "mssql finance loaded + wired (mount ${MSSQL_DB_ID})"
}

# ────────────────────────────────────────────────────────────────────────────
# DYNAMODB 'iot' — tables + items via AWS API to dynamodb-local, then registered
# ────────────────────────────────────────────────────────────────────────────
seed_dynamo() {
  if ! container_up mini-baas-dynamodb-local; then
    warn "dynamodb: mini-baas-dynamodb-local not running — skipping dynamodb"
    return 0
  fi
  local DDB_NET
  DDB_NET="$(docker inspect mini-baas-dynamodb-local \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)"
  [[ -n "${DDB_NET}" ]] || { warn "dynamodb: container network not found — skipping"; return 0; }
  ddb_create() { # $1 table
    docker run --rm --network "${DDB_NET}" \
      -e AWS_ACCESS_KEY_ID=fake -e AWS_SECRET_ACCESS_KEY=fake -e AWS_DEFAULT_REGION=us-east-1 \
      amazon/aws-cli dynamodb create-table --endpoint-url http://dynamodb-local:8000 \
      --table-name "$1" \
      --attribute-definitions AttributeName=owner_pk,AttributeType=S AttributeName=id,AttributeType=S \
      --key-schema AttributeName=owner_pk,KeyType=HASH AttributeName=id,KeyType=RANGE \
      --billing-mode PAY_PER_REQUEST
  }

  step "dynamodb: creating tables (owner_pk HASH + id RANGE) — idempotent"
  local tbl
  for tbl in devices device_events alerts; do
    ddb_create "${tbl}" >/dev/null 2>&1 &&
      cyan "dynamo table ${tbl} created" || cyan "dynamo table ${tbl} present"
  done

  step "dynamodb: loading deterministic items (owner_pk = ${OWNER}) via batch-write"
  # The generator emits batch-write-item request JSON (≤25 items/request) per
  # line; each is fed to aws-cli on stdin. owner_pk = the owner principal so the
  # adapter's owner-partition Query returns them.
  local req tmp
  tmp="$(mktemp -d /tmp/xeng-ddb.XXXXXX)"
  DDB_OWNER="${OWNER}" python3 "${SCRIPT_DIR}/extra-engines-gen.py" iot "${tmp}"
  for req in "${tmp}"/batch-*.json; do
    [[ -e "${req}" ]] || break
    docker run --rm --network "${DDB_NET}" \
      -e AWS_ACCESS_KEY_ID=fake -e AWS_SECRET_ACCESS_KEY=fake -e AWS_DEFAULT_REGION=us-east-1 \
      -v "${req}:/req.json:ro" amazon/aws-cli \
      dynamodb batch-write-item --endpoint-url http://dynamodb-local:8000 \
      --request-items file:///req.json >/dev/null 2>&1 ||
      warn "dynamodb: a batch-write-item failed (continuing)"
  done
  rm -rf "${tmp}"

  step "dynamodb: registering mount 'osionos-iot'"
  register_mount dynamodb osionos-iot \
    "dynamodb://local?endpoint=http://dynamodb-local:8000&region=us-east-1&access_key=fake&secret_key=fake"
  if [[ "${REG_CODE}" != "201" && "${REG_CODE}" != "409" ]]; then
    warn "dynamodb: mount register failed (${REG_CODE}): $(head -c 200 /tmp/xeng-mount.json) — skipping"
    return 0
  fi
  DYNAMO_DB_ID="${REG_ID}"
  [[ -n "${DYNAMO_DB_ID}" ]] || { warn "dynamodb: no mount id — skipping"; DYNAMO_DB_ID=""; return 0; }

  # DynamoDB has no schema introspection (the adapter reports health unknown);
  # CHECK with an owner-scoped list of the devices table instead.
  local code
  code=$(gw -X POST "${KONG_URL}/query/v1/${DYNAMO_DB_ID}/tables/devices" \
    -H 'Content-Type: application/json' -d '{"op":"list","limit":1}')
  if [[ "${code}" != "200" && "${code}" != "201" ]]; then
    if [[ "${ROUTER_POOLS}" != *dynamo* ]]; then
      warn "dynamodb: not built into the running router (pools: ${ROUTER_POOLS:-?}) — rebuild the router image with DATA_PLANE_FEATURES='--features dynamodb' + recreate the container, then re-run. Items ARE loaded in dynamodb-local; mount kept; edges/assoc skipped."
    else
      warn "dynamodb: engine CHECK (list devices) returned ${code}: $(head -c 200 /tmp/xeng-gw.json) — mount kept but edges/assoc skipped"
    fi
    DYNAMO_DB_ID=""
    return 0
  fi
  pass "dynamodb iot loaded + wired (mount ${DYNAMO_DB_ID})"
}

# ────────────────────────────────────────────────────────────────────────────
# CROSS-ENGINE EDGES — interleaved, into commerce.public.edges
# ────────────────────────────────────────────────────────────────────────────
seed_edges() {
  step "edges: building interleaved cross-engine edges into commerce.public.edges"
  if [[ -z "${SQLITE_DB_ID}${MSSQL_DB_ID}${DYNAMO_DB_ID}" ]]; then
    warn "edges: no new mount wired — nothing to link"
    return 0
  fi
  # The generator emits a single COPY-free INSERT … ON CONFLICT DO NOTHING SQL
  # block with the rows already interleaved by kind so the bounded overview
  # (EDGE_FANOUT 1000) shows a mix. Empty dbIds drop their edge kind cleanly.
  EDGE_OWNER="${OWNER}" \
  EDGE_SQLITE="${SQLITE_DB_ID}" EDGE_MSSQL="${MSSQL_DB_ID}" EDGE_DYNAMO="${DYNAMO_DB_ID}" \
  EDGE_COMMERCE="${COMMERCE_DB_ID}" \
    python3 "${SCRIPT_DIR}/extra-engines-gen.py" edges |
    pg -d commerce -q -v ON_ERROR_STOP=1 >/dev/null ||
    { warn "edges: insert failed"; return 0; }
  pass "edges inserted (interleaved)"
}

# ────────────────────────────────────────────────────────────────────────────
# WORKSPACE ASSOCIATION — both shared workspaces, one row per new mount
# ────────────────────────────────────────────────────────────────────────────
assoc_one() { # $1 dbId, $2 engine, $3 label, $4 tables-array-literal
  [[ -n "$1" ]] || return 0
  local ws
  for ws in "${WS_ACME}" "${WS_MAIN}"; do
    pg -d postgres -q -c "
      INSERT INTO public.osionos_workspace_databases (workspace_id, db_id, engine, tables, label)
      VALUES ('${ws}','$1','$2','$4','$3')
      ON CONFLICT (workspace_id, db_id) DO UPDATE
        SET engine=EXCLUDED.engine, tables=EXCLUDED.tables, label=EXCLUDED.label" >/dev/null ||
      warn "assoc: $1 → ws ${ws} failed"
  done
}

seed_assoc() {
  step "assoc: associating new mounts with Acme Operations + dev.pro.photo main"
  assoc_one "${SQLITE_DB_ID}" sqlite   'Restaurant · SQLite' '{restaurant,menu,dish,restaurant_order,order_item,working_hours}'
  assoc_one "${MSSQL_DB_ID}"  mssql    'Finance · MSSQL'     '{invoices,invoice_lines,payments,gl_accounts,cost_centers}'
  assoc_one "${DYNAMO_DB_ID}" dynamodb 'IoT · DynamoDB'      '{devices,device_events,alerts}'
  pass "associations upserted for wired mounts"
}

# ── run ─────────────────────────────────────────────────────────────────────
seed_sqlite
seed_mssql
seed_dynamo
seed_edges
seed_assoc

green "[xeng] DONE — sqlite=${SQLITE_DB_ID:-<skipped>} mssql=${MSSQL_DB_ID:-<skipped>} dynamodb=${DYNAMO_DB_ID:-<skipped>} (owner ${OWNER})"
