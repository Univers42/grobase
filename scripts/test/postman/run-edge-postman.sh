#!/usr/bin/env bash
# **************************************************************************** #
#                                                                            #
#                                                        :::      ::::::::    #
#    run-edge-postman.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                            #
# **************************************************************************** #
#
# DATA-DRIVEN edge-case reliability runner for the Grobase data plane.
#
# Drives postman/grobase-edge.postman_collection.json against the RUNNING
# mini-baas stack via newman-in-Docker, ONCE PER CORPUS VECTOR
# (postman/corpus/edge-corpus.json, 1500+ distinct edge cases) using
# `newman --iteration-data`. Produces an htmlextra report under artifacts/test/.
#
# RELIABILITY (the 503 cure): the query-router keeps a verify-cache LRU — after
# ONE successful api-key verify, every same-key request is a cache HIT (no
# tenant-control round-trip, no 2 s verify-timeout, no 503 under load). So this
# runner provisions ONE tenant + key + mount, creates the scratch table, then
# WARMS by retrying a trivial list until HTTP 200. After warm, all 1500+
# iterations are cache hits. The tenant/key/mount are provisioned ONCE and
# reused across every iteration (never per-iteration).
#
# SAFE on the live stack: it CREATES exactly one throwaway tenant (unique slug
# per run) + its own scratch table; it never deletes or mutates other tenants.
#
# Usage:  bash scripts/test/run-edge-postman.sh
#         NEWMAN_IMAGE=mini-baas-newman:local bash scripts/test/run-edge-postman.sh
#
# This script writes the concrete env, warms the cache, prints the EXACT docker
# newman command, then executes it and a PASS/FAIL summary.

set -euo pipefail

# ── 42 banner ────────────────────────────────────────────────────────────────
cat <<'BANNER'
# **************************************************************************** #
#                                                                            #
#                                                        :::      ::::::::    #
#    Grobase edge corpus — data-driven reliability run  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    1500+ distinct edge vectors · one newman iteration per vector  +#+        #
#                                                 +#+#+#+#+#+   +#+            #
#    verify-cache WARMED first → cache hits → no 503 under load    #+#         #
#                                                     ###   ########.fr        #
#                                                                            #
# **************************************************************************** #
BANNER

# ── paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" # repo root (script now at scripts/test/postman/)
POSTMAN_DIR="${INFRA_DIR}/infra/config/postman"
CORPUS="${POSTMAN_DIR}/corpus/edge-corpus.json"
# EDGE_SMOKE=1 runs a representative per-category subset (fast, low stack load).
RUN_CORPUS_FILE="edge-corpus.json"
[[ "${EDGE_SMOKE:-0}" == "1" ]] && RUN_CORPUS_FILE="edge-corpus.smoke.json"
COLLECTION="grobase-edge.postman_collection.json"
GEN_ENV="grobase-edge.generated.env.json" # written into POSTMAN_DIR
REPORT_DIR="${INFRA_DIR}/artifacts/test"
NEWMAN_IMAGE="${NEWMAN_IMAGE:-mini-baas-newman:local}"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step() { cyan "[edge] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[edge] FAIL — $*"
  exit 1
}

# ── 0) prerequisites ───────────────────────────────────────────────────────
step "0/5 prerequisites (docker, jq, curl, running stack, corpus, collection)"
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v jq >/dev/null 2>&1 || fail "jq is required (emit env, count corpus)"
command -v curl >/dev/null 2>&1 || fail "curl is required (warm the verify-cache)"
docker inspect mini-baas-kong >/dev/null 2>&1 || fail "mini-baas-kong not running — start the stack (make up EDITION=full)"
docker inspect mini-baas-tenant-control >/dev/null 2>&1 || fail "mini-baas-tenant-control not running"
docker inspect mini-baas-postgres >/dev/null 2>&1 || fail "mini-baas-postgres not running"
[[ -f "${POSTMAN_DIR}/${COLLECTION}" ]] || fail "collection not found: ${POSTMAN_DIR}/${COLLECTION}"
[[ -f "${CORPUS}" ]] || fail "corpus not found: ${CORPUS} (merge corpus/corpus-*.json first)"
docker image inspect "${NEWMAN_IMAGE}" >/dev/null 2>&1 ||
  fail "newman image '${NEWMAN_IMAGE}' not found (build it — it ships htmlextra)"

CORPUS_COUNT="$(jq 'length' "${CORPUS}")"
[[ "${CORPUS_COUNT}" -ge 1000 ]] || fail "corpus has only ${CORPUS_COUNT} vectors (<1000)"
jq empty "${CORPUS}" >/dev/null 2>&1 || fail "corpus is not valid JSON"
ok "stack up · corpus ${CORPUS_COUNT} vectors · collection + newman image present"

# ── 1) provision ONE throwaway tenant + key + postgresql mount ──────────────
step "1/5 provision a throwaway tenant + key + mount (enterprise/max tier — all ops)"
# shellcheck source=/dev/null
source "${INFRA_DIR}/scripts/lib/lib-live-tenant.sh"
SLUG="edge-$(date +%s)-$$"
live_tenant_provision "${SLUG}" || fail "live_tenant_provision failed for ${SLUG}"
# Best-effort teardown of THIS run's tenant on exit (never fails the run).
trap 'live_tenant_cleanup || true; rm -f "${POSTMAN_DIR}/${GEN_ENV}" 2>/dev/null || true' EXIT
ok "tenant=${LIVE_TENANT_SLUG} dbId=${LIVE_TENANT_DB_ID} key=${LIVE_TENANT_API_KEY:0:12}… kong=${LIVE_KONG_URL}"

BASE_URL="${LIVE_KONG_URL}"
ANON_KEY="${LIVE_ANON_APIKEY}"
API_KEY="${LIVE_TENANT_API_KEY}"
DB_ID="${LIVE_TENANT_DB_ID}"
CRUD_TABLE="edge_scratch_$(date +%s)"

# ── 2a) PRE-WARM verify BEFORE the DDL ──────────────────────────────────────
# The DDL is the FIRST verify-dependent call; a brand-new key cold-misses the
# tenant-control verify cache. Hit a cheap verify-only call (a list on the
# not-yet-created table) until verify is up — any non-503/000 response proves
# verify passed AND warmed the cache, so the DDL below lands hot and succeeds
# on the first try instead of burning the 25-try 503 budget.
step "2a/5 PRE-WARM verify-cache before DDL (cheap call until verify up; ≤40 tries, 1s)"
PREWARM_BODY='{"op":"list","limit":1}'
pwarmed=0
for i in $(seq 1 40); do
  PW_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
    "${BASE_URL}/query/v1/${DB_ID}/tables/${CRUD_TABLE}" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' -d "${PREWARM_BODY}" 2>/dev/null || echo 000)"
  case "${PW_CODE}" in
  503 | 000)
    yellow "  … prewarm try ${i}/40 → HTTP ${PW_CODE} (verify cold; retry 1s)"
    sleep 1
    ;;
  *)
    ok "verify up after ${i} try/tries (HTTP ${PW_CODE}) — cache warmed for the DDL"
    pwarmed=1
    break
    ;;
  esac
done
[[ "${pwarmed}" == "1" ]] || fail "verify never came up in 40 tries (last HTTP ${PW_CODE})"

# ── 2) create the scratch table via the DDL route ───────────────────────────
step "2/5 create scratch table '${CRUD_TABLE}' (generous benign schema) via /schema/ddl"
# Generous benign column set so SUCCESS-expecting vectors find their columns
# (the corpus uses label/note/title/… + numeric n/qty/big/f); hostile vectors
# reference invalid identifiers and still get their expected 4xx. owner_id is
# auto-appended server-side; reserved cols stay server-controlled.
EDGE_TEXT_COLS="name label note title value email tags content description comment status category kind code color author slug data payload meta"
EDGE_INT_COLS="n qty big f price amount count age score total num"
DDL_BODY=$(jq -n --arg t "${CRUD_TABLE}" --arg tc "${EDGE_TEXT_COLS}" --arg ic "${EDGE_INT_COLS}" '{
  op: "create_table",
  table: $t,
  columns: (
    [ { name: "id", normalized_type: "text", nullable: false, default: null, enum_values: null } ]
    + ($tc | split(" ") | map({ name: ., normalized_type: "text",    nullable: true, default: null, enum_values: null }))
    + ($ic | split(" ") | map({ name: ., normalized_type: "integer", nullable: true, default: null, enum_values: null }))
  ),
  primary_key: ["id"]
}')
# The DDL is the FIRST verify-dependent call, so on a loaded box its COLD verify
# can hit the 2 s tenant-control timeout (503 auth_verify_unavailable). Retry
# until one verify succeeds — that success also warms the verify-cache.
DDL_CODE=000
for i in $(seq 1 25); do
  DDL_CODE="$(curl -s -o /tmp/edge-ddl.json -w '%{http_code}' --max-time 15 -X POST \
    "${BASE_URL}/query/v1/${DB_ID}/schema/ddl" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' -d "${DDL_BODY}" 2>/dev/null || echo 000)"
  case "${DDL_CODE}" in
  200 | 201)
    ok "scratch table created (HTTP ${DDL_CODE})"
    break
    ;;
  409)
    ok "scratch table already exists (HTTP 409) — reuse"
    break
    ;;
  503 | 000)
    yellow "  … DDL try ${i}/25 → HTTP ${DDL_CODE} (cold verify under load; retry 1s)"
    sleep 1
    ;;
  *) fail "DDL create_table failed (HTTP ${DDL_CODE}): $(cat /tmp/edge-ddl.json 2>/dev/null | head -c 240)" ;;
  esac
done
[[ "${DDL_CODE}" =~ ^(200|201|409)$ ]] || fail "DDL never succeeded in 25 tries (last HTTP ${DDL_CODE})"

# ── 3) WARM the verify-cache: retry a trivial list until HTTP 200 ───────────
step "3/5 WARM verify-cache: list limit:1 until HTTP 200 (≤30 tries, 0.5s backoff)"
WARM_BODY='{"op":"list","limit":1}'
warmed=0
for i in $(seq 1 30); do
  WARM_CODE="$(curl -s -o /tmp/edge-warm.json -w '%{http_code}' --max-time 15 -X POST \
    "${BASE_URL}/query/v1/${DB_ID}/tables/${CRUD_TABLE}" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' -d "${WARM_BODY}" 2>/dev/null || echo 000)"
  if [[ "${WARM_CODE}" == "200" || "${WARM_CODE}" == "201" ]]; then
    ok "verify-cache WARM after ${i} try/tries (HTTP ${WARM_CODE}) — subsequent same-key calls are cache hits"
    warmed=1
    break
  fi
  yellow "  … warm try ${i}/30 → HTTP ${WARM_CODE} (retrying after 0.5s)"
  sleep 0.5
done
[[ "${warmed}" == "1" ]] || fail "verify-cache never warmed to HTTP 200 in 30 tries (last HTTP ${WARM_CODE}: $(cat /tmp/edge-warm.json 2>/dev/null | head -c 240))"

# ── 4) write the concrete environment json (gitignored, mode 600) ───────────
step "4/5 write concrete env → ${POSTMAN_DIR}/${GEN_ENV}"
mkdir -p "${REPORT_DIR}"
jq -n \
  --arg baseUrl "${BASE_URL}" \
  --arg anonKey "${ANON_KEY}" \
  --arg apiKey "${API_KEY}" \
  --arg dbId "${DB_ID}" \
  --arg crudTable "${CRUD_TABLE}" \
  '{
    name: "Grobase edge (generated by run-edge-postman.sh)",
    values: [
      { key: "baseUrl",   value: $baseUrl,   enabled: true },
      { key: "anonKey",   value: $anonKey,   enabled: true },
      { key: "apiKey",    value: $apiKey,    enabled: true },
      { key: "dbId",      value: $dbId,      enabled: true },
      { key: "crudTable", value: $crudTable, enabled: true }
    ],
    _postman_variable_scope: "environment"
  }' >"${POSTMAN_DIR}/${GEN_ENV}"
chmod 600 "${POSTMAN_DIR}/${GEN_ENV}" 2>/dev/null || true
ok "env written (baseUrl/anonKey/apiKey/dbId/crudTable; mode 600, gitignored)"

# ── 5) run newman in Docker (host network → reach 127.0.0.1 services) ────────
HTML_REPORT="${REPORT_DIR}/edge-report.html"
step "5/5 run newman (${NEWMAN_IMAGE}) — one iteration per corpus vector → htmlextra"
# shellcheck disable=SC2054  # newman wants ONE comma-separated --reporters value, not split array elements
DOCKER_CMD=(docker run --rm --network host
  -v "${POSTMAN_DIR}:/etc/newman"
  -v "${REPORT_DIR}:/reports"
  "${NEWMAN_IMAGE}" run "/etc/newman/${COLLECTION}"
  --environment "/etc/newman/${GEN_ENV}"
  --iteration-data "/etc/newman/corpus/${RUN_CORPUS_FILE}"
  --delay-request 60
  --timeout-request 15000
  --reporters cli,htmlextra,json
  --reporter-htmlextra-export /reports/edge-report.html
  --reporter-json-export /reports/edge-run.json)

cyan "  exact command:"
printf '    %s\n' "${DOCKER_CMD[*]}"

# Background RE-WARMER: the query-router api-key cache (api-key.middleware.ts) has
# a 30 s TTL and only repopulates on a SUCCESSFUL verify. On a loaded shared box a
# re-verify can 503 and never refresh, cascading. This loop lands a successful
# verify every few seconds (the verify succeeds intermittently), keeping the cache
# hot for the whole run so newman's requests stay cache hits — no 503.
(while true; do
  curl -s -o /dev/null --max-time 8 -X POST \
    "${BASE_URL}/query/v1/${DB_ID}/tables/${CRUD_TABLE}" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' -d '{"op":"list","limit":1}' 2>/dev/null || true
  sleep 4
done) &
WARMER_PID=$!
trap 'kill "${WARMER_PID}" 2>/dev/null || true; live_tenant_cleanup || true; rm -f "${POSTMAN_DIR}/${GEN_ENV}" 2>/dev/null || true' EXIT
step "  re-warmer running (pid ${WARMER_PID}, every 4s) to keep the verify-cache hot"

set +e
"${DOCKER_CMD[@]}"
NEWMAN_RC=$?
set -e
kill "${WARMER_PID}" 2>/dev/null || true

# ── summary ──────────────────────────────────────────────────────────────────
echo
if [[ -f "${HTML_REPORT}" ]]; then ok "HTML report: ${HTML_REPORT}"; fi
if [[ ${NEWMAN_RC} -eq 0 ]]; then
  green "[edge] PASS — all ${CORPUS_COUNT} edge vectors asserted clean against the live data plane"
  green "[edge] report: ${HTML_REPORT}"
  exit 0
else
  red "[edge] FAIL — newman reported assertion/run failures (rc=${NEWMAN_RC}) across ${CORPUS_COUNT} vectors"
  red "[edge] inspect: ${HTML_REPORT}"
  exit "${NEWMAN_RC}"
fi
