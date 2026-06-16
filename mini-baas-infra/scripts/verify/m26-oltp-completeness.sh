#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m26-oltp-completeness.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M26: OLTP completeness SEMANTICS (m25 proves the matrix
# is honest; this proves the operations are CORRECT):
#
#   batch    pg/mysql are ATOMIC — a poison item rolls the whole batch back;
#            mongo/redis are ORDERED — items before the failure persist and
#            the summary reports ok / error / skipped per item.
#   aggregate count/sum return the right NUMBERS (not just 200s) on
#            pg / mysql / mongo, owner-scoped like every read.
#   upsert   42P10 (table can't arbitrate ON CONFLICT) is a 400 contract
#            error, never a 502; and the MySQL ON DUPLICATE KEY owner guard
#            means a foreign principal's upsert can NEVER steal a row
#            (the cross-owner hijack fix).
#   crud     value round-trips (update actually changes, delete removes).
#
# Usage: m26-oltp-completeness.sh [--live]  # --live = fail if stack is down

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ROUTER_DIR="${BAAS_DIR}/docker/services/data-plane-router"
POOL_DIR="${ROUTER_DIR}/crates/data-plane-pool/src"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
fail()  { red "[M26] FAIL: $*"; exit 1; }
step()  { cyan "[M26] ${*}"; }
pass()  { green "[M26] PASS: ${*}"; }
skip()  { yellow "[M26] SKIP: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

# ── 1) static: the completeness arms + the two safety fixes exist ────────────
step "static: batch/aggregate arms + safety fixes present in source"
for engine in postgres mysql mongo redis; do
  grep -q "fn run_batch" "${POOL_DIR}/${engine}.rs" || fail "${engine}: run_batch missing"
done
grep -q "fn run_aggregate" "${POOL_DIR}/mysql.rs" || fail "mysql: run_aggregate missing"
grep -q "fn run_aggregate" "${POOL_DIR}/mongo.rs" || fail "mongo: run_aggregate missing"
grep -q 'IF(`owner_id` = VALUES(`owner_id`)' "${POOL_DIR}/mysql.rs" \
  || fail "mysql upsert owner guard missing (cross-owner hijack fix)"
grep -q '42P10' "${POOL_DIR}/postgres.rs" \
  || fail "pg 42P10 (ON CONFLICT arbitration) classification missing"
grep -q "batch_items" \
  "${ROUTER_DIR}/crates/data-plane-core/src/operation.rs" \
  || fail "core batch_items() wire-contract helper missing"
grep -q "'batch'" "${BAAS_DIR}/src/apps/query-router/src/query/outbox.service.ts" \
  || fail "outbox MUTATING_OPS must include batch"
grep -q "class BatchOperationDto" \
  "${BAAS_DIR}/src/apps/query-router/src/query/dto/query.dto.ts" \
  || fail "gateway BatchOperationDto missing"
pass "all completeness arms + hijack/42P10 fixes present"

# ── 2) live semantics ────────────────────────────────────────────────────────
stack_up() { docker inspect mini-baas-kong >/dev/null 2>&1 \
          && docker inspect mini-baas-tenant-control >/dev/null 2>&1; }
if ! stack_up; then
  [[ "${LIVE}" == "1" ]] && fail "--live requested but the stack is down (make up EDITION=query)"
  skip "stack not running — live semantics skipped (make up EDITION=query, then re-run)"
  pass "M26 static gates green"
  exit 0
fi

# shellcheck source=lib-live-tenant.sh
source "${BAAS_DIR}/scripts/verify/lib-live-tenant.sh"

M26_EXTRA_MOUNTS=()
m26_cleanup() {
  local id
  for id in "${M26_EXTRA_MOUNTS[@]:-}"; do
    if [[ -n "${id}" ]]; then
      svc_auth DELETE "/databases/${id}" ""
      curl -s -o /dev/null -X DELETE \
        "${LIVE_KONG_URL}/admin/v1/databases/${id}" \
        -H "apikey: ${LIVE_SERVICE_APIKEY}" "${SVC_AUTH[@]}" \
        -H "X-Tenant-Id: ${LIVE_TENANT_SLUG}" || true
    fi
  done
  docker exec mini-baas-postgres psql -U "${PG_USER:-postgres}" -d "${PG_DB:-postgres}" -q \
    -c 'DROP TABLE IF EXISTS m26_probe; DROP TABLE IF EXISTS m26_nouniq;' >/dev/null 2>&1 || true
  docker exec mini-baas-mysql mysql -u"${MY_USER:-mini_baas}" -p"${MY_PASS:-mini_baas_pw}" \
    "${MY_DB:-mini_baas}" -e 'DROP TABLE IF EXISTS m26_probe;' >/dev/null 2>&1 || true
  live_tenant_cleanup
}
trap 'm26_cleanup' EXIT

step "live: provisioning tenant, second principal, per-engine mounts"
# Unique slug per run: the shared lib mints a fixed key name ("verify-probe"),
# and tenant/key deletes are soft, so a re-run against a fixed slug would
# collide on the key-name uniqueness constraint. A timestamped slug keeps
# every run independent (scratch tenants are cleaned up on EXIT regardless).
live_tenant_provision "m26-oltp-$(date +%s)" || fail "tenant provisioning failed"

# A SECOND api key = a second owner principal (api-key:<uuid>) in the SAME
# tenant — the attacker role for the hijack regression test.
m26kb='{"name":"m26-second-principal","scopes":["read","write"]}'
svc_auth POST "/v1/tenants/${LIVE_TENANT_SLUG}/keys" "${m26kb}"
code=$(curl -s -o /tmp/m26-key2.json -w '%{http_code}' -X POST \
  "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${LIVE_TENANT_SLUG}/keys" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "${m26kb}")
[[ "${code}" == "201" ]] || fail "second key mint failed (${code})"
KEY_B="$(_lt_json_field key < /tmp/m26-key2.json)"
[[ "${KEY_B}" == mbk_* ]] || fail "second key has unexpected shape"

register_mount() { # $1 engine, $2 dsn -> echoes mount id (errors to stderr)
  local code
  code=$(curl -s -o /tmp/m26-mount.json -w '%{http_code}' -X POST \
    "${LIVE_KONG_URL}/admin/v1/databases" \
    -H "apikey: ${LIVE_SERVICE_APIKEY}" -H "X-Tenant-Id: ${LIVE_TENANT_SLUG}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"$1\",\"name\":\"m26-$1-$$-$(date +%s)\",\"connection_string\":\"$2\"}")
  if [[ "${code}" != "201" ]]; then
    red "[M26] FAIL: $1 mount register failed (${code}): $(cat /tmp/m26-mount.json)" >&2
    return 1
  fi
  _lt_json_field id < /tmp/m26-mount.json
}

MY_USER="$(_lt_env mini-baas-mysql MYSQL_USER)";     MY_USER="${MY_USER:-mini_baas}"
MY_PASS="$(_lt_env mini-baas-mysql MYSQL_PASSWORD)"; MY_PASS="${MY_PASS:-mini_baas_pw}"
MY_DB="$(_lt_env mini-baas-mysql MYSQL_DATABASE)";   MY_DB="${MY_DB:-mini_baas}"
MG_USER="$(_lt_env mini-baas-mongo MONGO_INITDB_ROOT_USERNAME)"; MG_USER="${MG_USER:-mongo}"
MG_PASS="$(_lt_env mini-baas-mongo MONGO_INITDB_ROOT_PASSWORD)"; MG_PASS="${MG_PASS:-mongo}"
PG_USER="$(_lt_env mini-baas-postgres POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
PG_DB="$(_lt_env mini-baas-postgres POSTGRES_DB)";     PG_DB="${PG_DB:-postgres}"

DB_pg="${LIVE_TENANT_DB_ID}"
DB_my="$(register_mount mysql "mysql://${MY_USER}:${MY_PASS}@mysql:3306/${MY_DB}")"
DB_mg="$(register_mount mongodb "mongodb://${MG_USER}:${MG_PASS}@mongo:27017/m26probe?authSource=admin")"
DB_rd="$(register_mount redis "redis://redis:6379")"
M26_EXTRA_MOUNTS=("${DB_my}" "${DB_mg}" "${DB_rd}")

docker exec mini-baas-postgres psql -U "${PG_USER}" -d "${PG_DB}" -q -c \
  'CREATE TABLE IF NOT EXISTS m26_probe (id text PRIMARY KEY, name text, n integer, owner_id text, UNIQUE (owner_id, id));
   CREATE TABLE IF NOT EXISTS m26_nouniq (id text PRIMARY KEY, name text, owner_id text);' \
  || fail "pg scratch tables"
docker exec mini-baas-mysql mysql -u"${MY_USER}" -p"${MY_PASS}" "${MY_DB}" -e \
  'CREATE TABLE IF NOT EXISTS m26_probe (id varchar(64) PRIMARY KEY, name text, n int, owner_id varchar(255), UNIQUE KEY owner_id_id (owner_id, id));' \
  2>/dev/null || fail "mysql scratch table"
pass "tenant + 2 principals + 4 mounts + tables ready"

# gw <expected-code-prefix> <key> <db> <resource> <body>; response in /tmp/m26.json
# Retries the transient gateway-availability envelopes (429 throttle, 503
# auth_verify_unavailable when the query-router→tenant-control circuit breaker
# is open after a control-plane blip). The breaker cooldown can reach ~60s, so
# the budget here (6 attempts, 3·n backoff ≈ 63s) must outlast it — a real
# data-path 4xx/5xx is never one of these envelopes and fails immediately.
gw() {
  local want="$1" key="$2" db="$3" res="$4" body="$5" code attempt
  for attempt in 1 2 3 4 5 6; do
    code=$(curl -s -o /tmp/m26.json -w '%{http_code}' -X POST \
      "${LIVE_KONG_URL}/query/v1/${db}/tables/${res}" \
      -H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${key}" \
      -H 'Content-Type: application/json' -d "${body}")
    if [[ "${code}" == "429" ]] \
       || grep -q 'auth_verify_unavailable\|tenant-control unreachable' /tmp/m26.json 2>/dev/null; then
      [[ "${attempt}" -lt 6 ]] && { sleep $((attempt * 3)); continue; }
    fi
    break
  done
  [[ "${code}" == ${want}* ]] \
    || fail "expected ${want}xx got ${code} for ${res} ${body:0:90} → $(head -c 220 /tmp/m26.json)"
}
has() { grep -q "$1" /tmp/m26.json || fail "response missing $1: $(head -c 220 /tmp/m26.json)"; }
# Numeric field assertion tolerant of JSON type: SUM/aggregate results come
# back as a number on pg (bigint) but a STRING on mysql (DECIMAL, kept as text
# to preserve precision). `hasnum field value` matches "field":6 OR "field":"6".
hasnum() { grep -qE "\"$1\":\"?$2\"?" /tmp/m26.json \
  || fail "response missing $1=$2 (number or string): $(head -c 220 /tmp/m26.json)"; }

KEY_A="${LIVE_TENANT_API_KEY}"

# ── CRUD value round-trips (pg / mysql / mongo / redis) ──────────────────────
# Every engine keys on a normal `id` field. NB mongo's adapter reserves `_id`
# (clients can't set it — the server assigns an ObjectId), so a portable probe
# keys documents on a regular `id` field the adapter preserves, exactly like
# the relational engines and redis (which requires the field be named `id`).
step "crud: value round-trips on all four engines"
for spec in "pg:${DB_pg}:id" "my:${DB_my}:id" "mg:${DB_mg}:id" "rd:${DB_rd}:id"; do
  tag="${spec%%:*}"; rest="${spec#*:}"; db="${rest%%:*}"; idf="${rest#*:}"
  gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"insert\",\"data\":{\"${idf}\":\"c1\",\"name\":\"before\",\"n\":1}}"
  gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"update\",\"filter\":{\"${idf}\":\"c1\"},\"data\":{\"name\":\"after\"}}"
  gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"get\",\"filter\":{\"${idf}\":\"c1\"}}"
  has '"name":"after"'
  gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"delete\",\"filter\":{\"${idf}\":\"c1\"}}"
  gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"get\",\"filter\":{\"${idf}\":\"c1\"}}"
  grep -q '"name":"after"' /tmp/m26.json && fail "${tag}: delete did not remove the row"
done
pass "insert→update→get(value)→delete→get(gone) on pg/mysql/mongo/redis"

# ── aggregate correctness (numbers, not just 200s) ───────────────────────────
step "aggregate: count + sum return correct numbers (pg / mysql / mongo)"
for spec in "pg:${DB_pg}:id" "my:${DB_my}:id" "mg:${DB_mg}:id"; do
  tag="${spec%%:*}"; rest="${spec#*:}"; db="${rest%%:*}"; idf="${rest#*:}"
  for i in 1 2 3; do
    gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"insert\",\"data\":{\"${idf}\":\"a${i}\",\"name\":\"agg\",\"n\":${i}}}"
  done
  gw 2 "${KEY_A}" "${db}" m26_probe '{"op":"aggregate","aggregate":{"aggregates":[{"func":"count","alias":"total"},{"func":"sum","field":"n","alias":"sum_n"}]}}'
  hasnum total 3
  hasnum sum_n 6
  # group_by path: one group per n value
  gw 2 "${KEY_A}" "${db}" m26_probe '{"op":"aggregate","aggregate":{"groupBy":["n"],"aggregates":[{"func":"count","alias":"c"}]},"sort":{"n":"asc"},"limit":10}'
  hasnum c 1
done
pass "count=3, sum=6 and GROUP BY verified on pg/mysql/mongo"

# ── batch: ATOMIC on pg + mysql ──────────────────────────────────────────────
step "batch: poison item rolls the whole batch back on pg + mysql"
for spec in "pg:${DB_pg}" "my:${DB_my}"; do
  tag="${spec%%:*}"; db="${spec#*:}"
  # poison: b2 duplicates b1's PRIMARY KEY → whole batch must fail, NOTHING persists
  gw 4 "${KEY_A}" "${db}" m26_probe '{"op":"batch","operations":[
    {"op":"insert","data":{"id":"b1","name":"batch","n":1}},
    {"op":"insert","data":{"id":"b1","name":"poison","n":2}}]}'
  has 'batch item 1'
  gw 2 "${KEY_A}" "${db}" m26_probe '{"op":"list","filter":{"name":{"$eq":"batch"}},"limit":5}'
  grep -q '"id":"b1"' /tmp/m26.json && fail "${tag}: poison batch leaked item b1 (NOT atomic)"
  # clean batch commits both items, summary says atomic
  gw 2 "${KEY_A}" "${db}" m26_probe '{"op":"batch","operations":[
    {"op":"insert","data":{"id":"b1","name":"batch","n":1}},
    {"op":"insert","data":{"id":"b2","name":"batch","n":2}}]}'
  has '"atomic":true'
  gw 2 "${KEY_A}" "${db}" m26_probe '{"op":"aggregate","aggregate":{"aggregates":[{"func":"count","alias":"total"}]},"filter":{"name":{"$eq":"batch"}}}'
  hasnum total 2
done
pass "pg/mysql batches are all-or-nothing (poison → zero rows; clean → both)"

# ── batch: ORDERED on mongo + redis ──────────────────────────────────────────
# Poison = a sub-op that deterministically 4xx's mid-batch (an empty-filter
# update is refused as a mass-write on mongo; a redis op with no id field is
# refused). The item BEFORE it must persist; the item AFTER must be skipped.
step "batch: ordered stop-on-first-error on mongo + redis"
for spec in "mg:${DB_mg}:id" "rd:${DB_rd}:id"; do
  tag="${spec%%:*}"; rest="${spec#*:}"; db="${rest%%:*}"; idf="${rest#*:}"
  poison='{"op":"update","filter":{},"data":{"name":"x"}}'
  [[ "${tag}" == "rd" ]] && poison='{"op":"get","filter":{"nope":"missing-id-field"}}'
  gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"batch\",\"operations\":[
    {\"op\":\"insert\",\"data\":{\"${idf}\":\"o1\",\"name\":\"ordered\"}},
    ${poison},
    {\"op\":\"insert\",\"data\":{\"${idf}\":\"o3\",\"name\":\"ordered\"}}]}"
  has '"atomic":false'
  has '"status":"error"'
  has '"status":"skipped"'
  gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"get\",\"filter\":{\"${idf}\":\"o1\"}}"
  has '"name":"ordered"'   # item BEFORE the failure persisted
  gw 2 "${KEY_A}" "${db}" m26_probe "{\"op\":\"get\",\"filter\":{\"${idf}\":\"o3\"}}"
  grep -q '"rowCount":0' /tmp/m26.json || fail "${tag}: skipped item o3 was executed (not skipped)"
done
pass "mongo/redis batches stop at the failure; earlier items persist, later skip"

# ── upsert: 42P10 is a 400 contract error, never 502 ─────────────────────────
step "upsert: table without composite UNIQUE → 400 with the contract spelled out"
gw 4 "${KEY_A}" "${DB_pg}" m26_nouniq '{"op":"upsert","filter":{"id":"u1"},"data":{"id":"u1","name":"x"}}'
grep -q '"statusCode":502' /tmp/m26.json && fail "42P10 still maps to 502"
has 'composite UNIQUE'
pass "42P10 → 4xx invalid_request naming the (owner_id, keys) contract"

# ── upsert: MySQL cross-owner hijack regression ──────────────────────────────
step "upsert: foreign principal can NOT steal a row via ON DUPLICATE KEY (mysql)"
gw 2 "${KEY_A}" "${DB_my}" m26_probe '{"op":"insert","data":{"id":"h1","name":"victim","n":1}}'
# Principal B upserts the same PRIMARY KEY — the guarded update must no-op.
gw 2 "${KEY_B}" "${DB_my}" m26_probe '{"op":"upsert","filter":{"id":"h1"},"data":{"id":"h1","name":"stolen","n":99}}'
ROW="$(docker exec mini-baas-mysql mysql -u"${MY_USER}" -p"${MY_PASS}" "${MY_DB}" \
  -N -e "SELECT name, owner_id FROM m26_probe WHERE id='h1';" 2>/dev/null)"
grep -q "victim" <<<"${ROW}" || fail "mysql hijack: row name changed: ${ROW}"
grep -q "stolen" <<<"${ROW}" && fail "mysql hijack: foreign principal overwrote the row: ${ROW}"
# And principal A's view is intact through the API too.
gw 2 "${KEY_A}" "${DB_my}" m26_probe '{"op":"get","filter":{"id":"h1"}}'
has '"name":"victim"'
pass "mysql ON DUPLICATE KEY owner guard holds — no cross-owner overwrite"

green "[M26] ALL GATES GREEN — OLTP semantics verified end-to-end"
