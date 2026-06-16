#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m25-oltp-matrix.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M25: the OLTP operation matrix — END-TO-END capability
# honesty. The boot-time assertion (capability_honesty.rs) proves descriptor
# ↔ SUPPORTED_OPS inside the Rust process; this gate proves the SAME truth
# holds across the whole unified path a customer actually hits:
#
#   Kong key-auth → query-router DTO/proxy → Rust /v1/query → engine pool
#
# Static  : parse each adapter's SUPPORTED_OPS const and its descriptor in
#           capability.rs from SOURCE; derive both op sets; they must match.
#           (No toolchain needed — Docker-first stays intact.)
# Live    : provision a scratch (tenant, key, mount) per engine against the
#           RUNNING stack (EDITION=query) and probe ALL 8 DataOperationKind
#           values through the gateway. Canonicalize each probe:
#             2xx                → served
#             400/422/501       → unsupported (DTO whitelist, planner 422,
#                                  or adapter NotImplemented — all mean "the
#                                  platform refuses this op")
#             anything else      → error (the gate fails outright)
#           Assert served ⇔ /v1/capabilities flag for every (engine, op).
#           A descriptor that promises an op the path can't serve — or a
#           path that serves an op the descriptor denies — fails the gate.
#   http   : static-only (live probes need an HTTP target fixture; the M27
#            conformance suite owns that).
#
# Artifact: artifacts/oltp-matrix.json (observed × expected, per engine/op).
#
# Usage: m25-oltp-matrix.sh [--live]   # --live = fail if the stack is down
#                                      # (default: auto-skip live section)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ROUTER_DIR="${BAAS_DIR}/docker/services/data-plane-router"
POOL_DIR="${ROUTER_DIR}/crates/data-plane-pool/src"
CAP_RS="${ROUTER_DIR}/crates/data-plane-core/src/capability.rs"
ARTIFACT="${BAAS_DIR}/artifacts/oltp-matrix.json"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
fail()  { red "[M25] FAIL: $*"; exit 1; }
step()  { cyan "[M25] ${*}"; }
pass()  { green "[M25] PASS: ${*}"; }
skip()  { yellow "[M25] SKIP: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

ALL_OPS="list get insert update delete upsert batch aggregate"

# engine name (descriptor/compose) -> adapter source file stem
src_of() {
  case "$1" in
    postgresql) echo postgres ;;
    mongodb)    echo mongo ;;
    *)          echo "$1" ;;
  esac
}

# ── 1) static: SUPPORTED_OPS (dispatch surface) per adapter, from source ─────
ops_from_source() { # $1 engine
  sed -n '/SUPPORTED_OPS: &\[DataOperationKind\]/,/];/p' \
    "${POOL_DIR}/$(src_of "$1").rs" \
    | grep -o 'DataOperationKind::[A-Za-z]*' \
    | sed 's/DataOperationKind:://' | tr '[:upper:]' '[:lower:]' | sort -u
}

# ── 2) static: descriptor flags per engine, from capability.rs ───────────────
ops_from_descriptor() { # $1 engine
  local block flag ops=""
  block="$(sed -n "/pub fn $1() -> Self {/,/^    }$/p" "${CAP_RS}")"
  [[ -n "${block}" ]] || fail "no EngineCapabilities::$1() constructor in capability.rs"
  flag() { grep -qE "^\s*$1: true," <<<"${block}"; }
  flag read      && ops+="list get "
  flag write     && ops+="insert update delete "
  flag upsert    && ops+="upsert "
  flag batch     && ops+="batch "
  flag aggregate && ops+="aggregate "
  tr ' ' '\n' <<<"${ops}" | sed '/^$/d' | sort -u
}

step "static: dispatch surface (SUPPORTED_OPS) must equal descriptor promise"
ENGINES="postgresql mysql mongodb redis http"
declare -A EXPECTED  # engine -> space-joined sorted op list
for engine in ${ENGINES}; do
  dispatch="$(ops_from_source "${engine}")"
  promised="$(ops_from_descriptor "${engine}")"
  [[ -n "${dispatch}" ]] || fail "could not parse SUPPORTED_OPS for ${engine}"
  if [[ "${dispatch}" != "${promised}" ]]; then
    red  "  ${engine} dispatch : $(tr '\n' ' ' <<<"${dispatch}")"
    red  "  ${engine} promised : $(tr '\n' ' ' <<<"${promised}")"
    fail "descriptor↔dispatch drift for ${engine}"
  fi
  EXPECTED[${engine}]="$(tr '\n' ' ' <<<"${promised}" | sed 's/ $//')"
  echo "  ${engine}: ${EXPECTED[${engine}]}"
done
pass "all 5 engines: descriptor flags == SUPPORTED_OPS (parsed from source)"

step "static: boot-time honesty assertion is still wired"
grep -q "assert_capability_honesty" \
  "${ROUTER_DIR}/crates/data-plane-server/src/routes.rs" \
  || fail "routes.rs no longer calls assert_capability_honesty at boot"
pass "assert_capability_honesty still guards AppState::new"

# ── 3) live: probe the full gateway path per engine ─────────────────────────
stack_up() { docker inspect mini-baas-kong >/dev/null 2>&1 \
          && docker inspect mini-baas-tenant-control >/dev/null 2>&1; }

if ! stack_up; then
  [[ "${LIVE}" == "1" ]] && fail "--live requested but the stack is down (make up EDITION=query)"
  skip "stack not running — live matrix probes skipped (run: make up EDITION=query, then make verify-m25)"
  pass "M25 static gates green"
  exit 0
fi

# shellcheck source=lib-live-tenant.sh
source "${BAAS_DIR}/scripts/verify/lib-live-tenant.sh"

step "live: provisioning scratch tenant + per-engine mounts"
trap 'm25_cleanup' EXIT
M25_EXTRA_MOUNTS=()
m25_cleanup() {
  local id
  for id in "${M25_EXTRA_MOUNTS[@]:-}"; do
    if [[ -n "${id}" ]]; then
      svc_auth DELETE "/databases/${id}" ""
      curl -s -o /dev/null -X DELETE \
        "${LIVE_KONG_URL}/admin/v1/databases/${id}" \
        -H "apikey: ${LIVE_SERVICE_APIKEY}" "${SVC_AUTH[@]}" \
        -H "X-Tenant-Id: ${LIVE_TENANT_SLUG}" || true
    fi
  done
  docker exec mini-baas-postgres psql -U "${PG_USER:-postgres}" -d "${PG_DB:-postgres}" \
    -c 'DROP TABLE IF EXISTS m25_probe;' >/dev/null 2>&1 || true
  docker exec mini-baas-mysql mysql -u"${MY_USER:-mini_baas}" -p"${MY_PASS:-mini_baas_pw}" \
    "${MY_DB:-mini_baas}" -e 'DROP TABLE IF EXISTS m25_probe;' >/dev/null 2>&1 || true
  live_tenant_cleanup
}
# Unique slug per run: the shared lib mints a fixed key name and tenant/key
# deletes are soft, so a fixed slug would collide on re-run (key-name unique
# constraint). Scratch tenants are cleaned up on EXIT regardless.
live_tenant_provision "m25-matrix-$(date +%s)" || fail "scratch tenant provisioning failed"

# extra mounts: mysql / mongodb / redis (DSNs from the live containers,
# in-network aliases — the same trust path lib-live-tenant uses for pg).
# Names are unique per run so a previous run's leftovers can never 409 us;
# stdout carries ONLY the mount id (this runs in command substitution, so
# diagnostics must go to stderr).
register_mount() { # $1 engine, $2 dsn -> echoes mount id
  local code
  code=$(curl -s -o /tmp/m25-mount.json -w '%{http_code}' -X POST \
    "${LIVE_KONG_URL}/admin/v1/databases" \
    -H "apikey: ${LIVE_SERVICE_APIKEY}" -H "X-Tenant-Id: ${LIVE_TENANT_SLUG}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"$1\",\"name\":\"m25-$1-$$-$(date +%s)\",\"connection_string\":\"$2\"}")
  if [[ "${code}" != "201" ]]; then
    red "[M25] FAIL: $1 mount register failed (${code}): $(cat /tmp/m25-mount.json)" >&2
    return 1
  fi
  _lt_json_field id < /tmp/m25-mount.json
}

MY_USER="$(_lt_env mini-baas-mysql MYSQL_USER)";         MY_USER="${MY_USER:-mini_baas}"
MY_PASS="$(_lt_env mini-baas-mysql MYSQL_PASSWORD)";     MY_PASS="${MY_PASS:-mini_baas_pw}"
MY_DB="$(_lt_env mini-baas-mysql MYSQL_DATABASE)";       MY_DB="${MY_DB:-mini_baas}"
MG_USER="$(_lt_env mini-baas-mongo MONGO_INITDB_ROOT_USERNAME)"; MG_USER="${MG_USER:-mongo}"
MG_PASS="$(_lt_env mini-baas-mongo MONGO_INITDB_ROOT_PASSWORD)"; MG_PASS="${MG_PASS:-mongo}"
PG_USER="$(_lt_env mini-baas-postgres POSTGRES_USER)";   PG_USER="${PG_USER:-postgres}"
PG_DB="$(_lt_env mini-baas-postgres POSTGRES_DB)";       PG_DB="${PG_DB:-postgres}"

DB_pg="${LIVE_TENANT_DB_ID}"
DB_my="$(register_mount mysql "mysql://${MY_USER}:${MY_PASS}@mysql:3306/${MY_DB}")"
DB_mg="$(register_mount mongodb "mongodb://${MG_USER}:${MG_PASS}@mongo:27017/m25probe?authSource=admin")"
DB_rd="$(register_mount redis "redis://redis:6379")"
M25_EXTRA_MOUNTS=("${DB_my}" "${DB_mg}" "${DB_rd}")
pass "mounts registered: pg=${DB_pg} my=${DB_my} mg=${DB_mg} rd=${DB_rd}"

step "live: creating scratch tables (pg + mysql; mongo/redis are implicit)"
# Platform table contract under shared_rls: ids are owner-namespaced, so the
# pg upsert arbitrates ON CONFLICT (owner_id, <filter keys>) — tables that
# want upsert MUST carry the matching composite UNIQUE constraint.
docker exec mini-baas-postgres psql -U "${PG_USER}" -d "${PG_DB}" -q -c \
  'CREATE TABLE IF NOT EXISTS m25_probe (id text PRIMARY KEY, name text, n integer, owner_id text, UNIQUE (owner_id, id));' \
  || fail "pg scratch table"
docker exec mini-baas-mysql mysql -u"${MY_USER}" -p"${MY_PASS}" "${MY_DB}" -e \
  'CREATE TABLE IF NOT EXISTS m25_probe (id varchar(64) PRIMARY KEY, name text, n int, owner_id varchar(255), UNIQUE KEY owner_id_id (owner_id, id));' \
  2>/dev/null || fail "mysql scratch table"
pass "scratch tables ready"

# one probe through the WHOLE path; canonicalize the outcome
probe() { # $1 dbId, $2 body -> echoes served|unsupported|error:<code>
  local code attempt
  for attempt in 1 2 3 4 5 6; do
    code=$(curl -s -o /tmp/m25-probe.json -w '%{http_code}' -X POST \
      "${LIVE_KONG_URL}/query/v1/$1/tables/m25_probe" \
      -H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${LIVE_TENANT_API_KEY}" \
      -H 'Content-Type: application/json' -d "$2")
    # Ride out a query-router→tenant-control circuit-breaker window (~60s)
    # the same way the m26 gate does — these are availability blips, not the
    # capability signal the matrix is measuring.
    if [[ "${code}" == "429" ]] \
       || grep -q 'auth_verify_unavailable\|tenant-control unreachable' /tmp/m25-probe.json 2>/dev/null; then
      [[ "${attempt}" -lt 6 ]] && { sleep $((attempt * 3)); continue; }
    fi
    break
  done
  case "${code}" in
    2*)            echo served ;;
    400|422|501)   echo unsupported ;;
    *)             echo "error:${code}" ;;
  esac
}

# probe bodies — id column is `_id` on mongo, `id` elsewhere. Order matters:
# the row inserted first feeds get/update/upsert; delete runs last.
body_for() { # $1 op, $2 idfield
  local id="$2"
  case "$1" in
    insert)    echo "{\"op\":\"insert\",\"data\":{\"${id}\":\"m25-a\",\"name\":\"alpha\",\"n\":1}}" ;;
    get)       echo "{\"op\":\"get\",\"filter\":{\"${id}\":\"m25-a\"}}" ;;
    list)      echo '{"op":"list","limit":2}' ;;
    update)    echo "{\"op\":\"update\",\"filter\":{\"${id}\":\"m25-a\"},\"data\":{\"name\":\"beta\"}}" ;;
    upsert)    echo "{\"op\":\"upsert\",\"filter\":{\"${id}\":\"m25-a\"},\"data\":{\"${id}\":\"m25-a\",\"name\":\"gamma\"}}" ;;
    aggregate) echo '{"op":"aggregate","aggregate":{"aggregates":[{"func":"count","alias":"total"}]}}' ;;
    batch)     echo "{\"op\":\"batch\",\"operations\":[{\"op\":\"insert\",\"data\":{\"${id}\":\"m25-b\",\"name\":\"x\"}}]}" ;;
    delete)    echo "{\"op\":\"delete\",\"filter\":{\"${id}\":\"m25-a\"}}" ;;
  esac
}

step "live: probing 8 ops × 4 engines through Kong"
PROBE_ORDER="insert get list update upsert aggregate batch delete"
declare -A OBSERVED  # "engine/op" -> served|unsupported|error:<code>
VIOLATIONS=0
for pair in "postgresql:${DB_pg}:id" "mysql:${DB_my}:id" "mongodb:${DB_mg}:_id" "redis:${DB_rd}:id"; do
  engine="${pair%%:*}"; rest="${pair#*:}"; db="${rest%%:*}"; idf="${rest#*:}"
  for op in ${PROBE_ORDER}; do
    out="$(probe "${db}" "$(body_for "${op}" "${idf}")")"
    OBSERVED[${engine}/${op}]="${out}"
    want="unsupported"
    grep -qw "${op}" <<<"${EXPECTED[${engine}]}" && want="served"
    if [[ "${out}" == error:* ]]; then
      red "  ${engine}/${op}: ${out} (5xx/unexpected — never acceptable)"
      VIOLATIONS=$((VIOLATIONS + 1))
    elif [[ "${out}" != "${want}" ]]; then
      red "  ${engine}/${op}: observed=${out} expected=${want}"
      VIOLATIONS=$((VIOLATIONS + 1))
    else
      echo "  ${engine}/${op}: ${out} ✓"
    fi
  done
done

step "writing ${ARTIFACT}"
mkdir -p "$(dirname "${ARTIFACT}")"
{
  echo '{'
  echo "  \"generated\": \"$(date -u +%FT%TZ)\","
  echo '  "engines": {'
  first_e=1
  for engine in postgresql mysql mongodb redis; do
    [[ ${first_e} == 0 ]] && echo ','
    first_e=0
    printf '    "%s": {' "${engine}"
    first_o=1
    for op in ${ALL_OPS}; do
      [[ ${first_o} == 0 ]] && printf ','
      first_o=0
      want=false
      grep -qw "${op}" <<<"${EXPECTED[${engine}]}" && want=true
      printf '"%s": {"observed": "%s", "promised": %s}' \
        "${op}" "${OBSERVED[${engine}/${op}]:-unprobed}" "${want}"
    done
    printf '}'
  done
  echo ''
  echo '  },'
  echo "  \"http\": \"static-only (descriptor == SUPPORTED_OPS verified from source)\","
  echo "  \"violations\": ${VIOLATIONS}"
  echo '}'
} > "${ARTIFACT}"

[[ "${VIOLATIONS}" == "0" ]] || fail "${VIOLATIONS} matrix violation(s) — see ${ARTIFACT}"
pass "live matrix == descriptors for postgresql/mysql/mongodb/redis (http static-only)"
green "[M25] ALL GATES GREEN — the OLTP matrix is honest end-to-end"
