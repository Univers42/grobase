#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    run-postman.sh                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Offer-capability proof runner: drives postman/grobase-offers.postman_collection.json
# against the RUNNING mini-baas stack with newman-in-Docker, producing an HTML
# (htmlextra) + JUnit report under artifacts/test/.
#
# It discovers every live secret from the RUNNING containers — the SAME way
# scripts/lib/lib-live-tenant.sh does (never from the caller's shell, so a
# wrong host env can't poison the run):
#   - X-Service-Token  : tenant-control container env INTERNAL_SERVICE_TOKEN
#                        (lib-live-tenant.sh line: LIVE_SERVICE_TOKEN="$(_lt_env
#                         mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)")
#   - Kong anon key    : mini-baas-kong env KONG_PUBLIC_API_KEY  (apikey consumer)
#   - Kong service key : mini-baas-kong env KONG_SERVICE_API_KEY (admin routes)
#   - postgres DSN     : mini-baas-postgres POSTGRES_{USER,PASSWORD,DB}, dialled
#                        via the in-network alias `postgres:5432`
#   - JWT secret       : mini-baas-gotrue GOTRUE_JWT_SECRET (m55/m56 mint_jwt) —
#                        used by the storage/functions folders to mint a user JWT
#
# SAFE on the live stack: the collection only CREATES a throwaway test tenant
# (unique slug per run) and its own scratch table/bucket/function; it never
# deletes or mutates other tenants.
#
# Usage:  bash scripts/test/run-postman.sh
#         NEWMAN_IMAGE=postman/newman:6-alpine bash scripts/test/run-postman.sh
#
# The orchestrator runs newman; this script writes the concrete env + prints the
# exact docker command, then executes it and a PASS/FAIL summary.

set -euo pipefail

# ── paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"          # repo root (script now at scripts/test/postman/)
POSTMAN_DIR="${INFRA_DIR}/postman"
REPORT_DIR="${INFRA_DIR}/artifacts/test"
COLLECTION="grobase-offers.postman_collection.json"
GEN_ENV="grobase-offers.generated.env.json"            # written into POSTMAN_DIR
NEWMAN_IMAGE="${NEWMAN_IMAGE:-postman/newman:6-alpine}"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
step()  { cyan "[postman] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[postman] FAIL — $*"; exit 1; }

# Read a container env var (works for distroless images — same as lib-live-tenant.sh _lt_env).
_env() { # $1 container, $2 var
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep "^$2=" | head -1 | cut -d= -f2-
}

# Host port a container publishes for $2 (e.g. 8000/tcp) — empty if unmapped.
_host_port() { # $1 container, $2 container-port/proto
  docker port "$1" "$2" 2>/dev/null | head -1 | sed 's/.*://'
}

# ── 0) prerequisites ───────────────────────────────────────────────────────
step "0/4 prerequisites (docker, jq, running stack)"
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v jq     >/dev/null 2>&1 || fail "jq is required (parse/emit the env json)"
docker inspect mini-baas-kong           >/dev/null 2>&1 || fail "mini-baas-kong not running — start the stack (make up EDITION=full)"
docker inspect mini-baas-tenant-control >/dev/null 2>&1 || fail "mini-baas-tenant-control not running"
docker inspect mini-baas-postgres       >/dev/null 2>&1 || fail "mini-baas-postgres not running"
[[ -f "${POSTMAN_DIR}/${COLLECTION}" ]] || fail "collection not found: ${POSTMAN_DIR}/${COLLECTION}"

# Resolve host ports (resolve-ports.sh may have moved them off the defaults).
KONG_PORT="$(_host_port mini-baas-kong 8000/tcp)";            KONG_PORT="${KONG_PORT:-8002}"
TC_PORT="$(_host_port mini-baas-tenant-control 3022/tcp)";    TC_PORT="${TC_PORT:-3022}"
DP_PORT="$(_host_port mini-baas-data-plane-router-rust 4011/tcp 2>/dev/null || true)"; DP_PORT="${DP_PORT:-4011}"
BASE_URL="http://127.0.0.1:${KONG_PORT}"
CONTROL_URL="http://127.0.0.1:${TC_PORT}"
DATA_PLANE_URL="http://127.0.0.1:${DP_PORT}"

# Confirm Kong itself is up (a route 404 still proves the gateway answers).
KONG_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${BASE_URL}/" 2>/dev/null || echo 000)"
[[ "${KONG_CODE}" != "000" ]] || fail "Kong did not answer on ${BASE_URL} (is the stack up?)"
ok "stack up — Kong ${BASE_URL} (HTTP ${KONG_CODE}), control ${CONTROL_URL}, data plane ${DATA_PLANE_URL}"

# ── 1) discover live secrets from the running containers ───────────────────
step "1/4 discover live secrets from running containers (mirrors lib-live-tenant.sh)"
SERVICE_TOKEN="$(_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
ANON_KEY="$(_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SERVICE_API_KEY="$(_env mini-baas-kong KONG_SERVICE_API_KEY)"
[[ -n "${SERVICE_TOKEN}"   ]] || fail "INTERNAL_SERVICE_TOKEN not found on mini-baas-tenant-control"
[[ -n "${ANON_KEY}"        ]] || fail "KONG_PUBLIC_API_KEY not found on mini-baas-kong"
[[ -n "${SERVICE_API_KEY}" ]] || fail "KONG_SERVICE_API_KEY not found on mini-baas-kong"

# postgres DSN via the in-network alias (the data plane dials `postgres:5432`).
PG_USER="$(_env mini-baas-postgres POSTGRES_USER)";     PG_USER="${PG_USER:-postgres}"
PG_PASS="$(_env mini-baas-postgres POSTGRES_PASSWORD)"; PG_PASS="${PG_PASS:-postgres}"
PG_DB="$(_env mini-baas-postgres POSTGRES_DB)";         PG_DB="${PG_DB:-postgres}"
PG_DSN="postgres://${PG_USER}:${PG_PASS}@postgres:5432/${PG_DB}"

# JWT secret for the storage/functions folders (m55/m56 discovery order).
JWT_SECRET="$(_env mini-baas-gotrue GOTRUE_JWT_SECRET)"
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET="$(_env mini-baas-kong JWT_SECRET)"
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET="$(_env mini-baas-storage-router JWT_SECRET 2>/dev/null || true)"
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET="$(grep -E '^JWT_SECRET=' "${INFRA_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
if [[ -z "${JWT_SECRET}" ]]; then
  yellow "  ! JWT_SECRET not discovered — storage (80) + functions (90) folders will SKIP (they need a user JWT)"
fi
ok "secrets discovered (service-token, anon+service Kong keys, pg DSN${JWT_SECRET:+, jwt secret})"

# ── 2) write the concrete environment json (blanks filled, NEVER committed) ─
step "2/4 write concrete env → ${POSTMAN_DIR}/${GEN_ENV}"
mkdir -p "${REPORT_DIR}"
jq -n \
  --arg baseUrl "${BASE_URL}" \
  --arg controlUrl "${CONTROL_URL}" \
  --arg dataPlaneUrl "${DATA_PLANE_URL}" \
  --arg serviceToken "${SERVICE_TOKEN}" \
  --arg anonKey "${ANON_KEY}" \
  --arg serviceApiKey "${SERVICE_API_KEY}" \
  --arg pgDsn "${PG_DSN}" \
  --arg jwtSecret "${JWT_SECRET}" \
  '{
    name: "Grobase local (generated by run-postman.sh)",
    values: [
      { key: "baseUrl",       value: $baseUrl,       enabled: true },
      { key: "controlUrl",    value: $controlUrl,    enabled: true },
      { key: "dataPlaneUrl",  value: $dataPlaneUrl,  enabled: true },
      { key: "serviceToken",  value: $serviceToken,  enabled: true },
      { key: "anonKey",       value: $anonKey,       enabled: true },
      { key: "serviceApiKey", value: $serviceApiKey, enabled: true },
      { key: "pgDsn",         value: $pgDsn,         enabled: true },
      { key: "jwtSecret",     value: $jwtSecret,     enabled: true },
      { key: "apiKey",        value: "",             enabled: true },
      { key: "dbId",          value: "",             enabled: true },
      { key: "slug",          value: "",             enabled: true },
      { key: "keyId",         value: "",             enabled: true },
      { key: "mountName",     value: "",             enabled: true },
      { key: "jwt",           value: "",             enabled: true },
      { key: "authEmail",     value: "",             enabled: true },
      { key: "authPassword",  value: "",             enabled: true },
      { key: "crudTable",     value: "",             enabled: true },
      { key: "bucket",        value: "",             enabled: true },
      { key: "storageSub",    value: "",             enabled: true },
      { key: "storageJwt",    value: "",             enabled: true },
      { key: "fnName",        value: "",             enabled: true }
    ],
    _postman_variable_scope: "environment"
  }' > "${POSTMAN_DIR}/${GEN_ENV}"
chmod 600 "${POSTMAN_DIR}/${GEN_ENV}" 2>/dev/null || true
ok "env written (mode 600 — contains live secrets, gitignored)"

# ── 3) run newman in Docker (host network → reach 127.0.0.1 services) ───────
HTML_REPORT="${REPORT_DIR}/postman-offers-report.html"
JUNIT_REPORT="${REPORT_DIR}/postman-offers.xml"
step "3/4 run newman (${NEWMAN_IMAGE}) → HTML + JUnit"
DOCKER_CMD=(docker run --rm --network host
  -v "${POSTMAN_DIR}:/etc/newman"
  -v "${REPORT_DIR}:/reports"
  "${NEWMAN_IMAGE}" run "/etc/newman/${COLLECTION}"
  --environment "/etc/newman/${GEN_ENV}"
  --delay-request "${NEWMAN_DELAY:-300}"
  --timeout-request "${NEWMAN_REQ_TIMEOUT:-15000}"
  --reporters cli,htmlextra,junit
  --reporter-htmlextra-export /reports/postman-offers-report.html
  --reporter-junit-export /reports/postman-offers.xml)

cyan "  exact command:"
printf '    %s\n' "${DOCKER_CMD[*]}"

set +e
"${DOCKER_CMD[@]}"
NEWMAN_RC=$?
set -e

# Drop the generated env (it carries live secrets) — reports keep the evidence.
rm -f "${POSTMAN_DIR}/${GEN_ENV}" 2>/dev/null || true

# ── 4) summary ─────────────────────────────────────────────────────────────
step "4/4 summary"
if [[ -f "${HTML_REPORT}" ]]; then ok "HTML report: ${HTML_REPORT}"; fi
if [[ -f "${JUNIT_REPORT}" ]]; then ok "JUnit  report: ${JUNIT_REPORT}"; fi

if [[ ${NEWMAN_RC} -eq 0 ]]; then
  green "[postman] PASS — every Grobase offer capability assertion passed against the live stack"
  green "[postman] report: ${HTML_REPORT}"
  exit 0
else
  red "[postman] FAIL — newman reported assertion/run failures (rc=${NEWMAN_RC})"
  red "[postman] inspect: ${HTML_REPORT}"
  exit "${NEWMAN_RC}"
fi
