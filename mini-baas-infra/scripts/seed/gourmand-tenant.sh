#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    gourmand-tenant.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Mount vite-gourmand's PostgreSQL (their REAL Supabase project) as a live
# `tenant_owned` mount, so the osionos dashboards read/write the restaurant's
# actual tables. Unlike agency-tenant.sh this script NEVER creates databases
# or tables — the schema is the client's own (Prisma-managed, ~48 PascalCase
# tables) and is only introspected.
#
# DSN source order (first hit wins):
#   1. GOURMAND_DB_DSN env var
#   2. apps/vite-gourmand/Back/.env → DIRECT_URL  (session port 5432 — the
#      data plane uses prepared statements, the 6543 transaction pooler
#      would break them)
#   3. apps/vite-gourmand/Back/.env → DATABASE_URL (port 6543 rewritten to
#      5432 with a warning)
#   4. dev fallback: vite-gourmand's local compose postgres via
#      host.docker.internal:5432/vite_gourmand (requires their stack up and
#      the root track-binocle postgres NOT holding host 5432)
# Back/.env is materialized by vite-gourmand's Bitwarden flow:
#   cd apps/vite-gourmand && make secrets   (interactive — bw master password)
#
# Identity model (matches seed-live-demo.sh): the mount registers under the
# OSIONOS APP KEY's tenant so this dev instance's app sees it directly. A
# dedicated `gourmand` tenant + per-deployment key is the production posture
# (set BAAS_API_KEY to that key and re-run).
#
# Supabase notes enforced here: host *.supabase.co|.com gets sslmode=require
# appended when missing (TLS is mandatory there; the data plane's rustls
# connector engages on sslmode=require/verify-*).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# v1 HMAC service auth (audit O1) — signs the tenant-control call under hmac mode.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/service-auth.sh"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${INFRA_ROOT}/../../.." && pwd)"
STATE_ENV="${INFRA_ROOT}/.gourmand-tenant.env"
APP_ENV_FILE="${APP_ENV_FILE:-${REPO_ROOT}/apps/osionos/app/.env}"
VG_ENV_FILE="${VG_ENV_FILE:-${REPO_ROOT}/apps/vite-gourmand/Back/.env}"
MOUNT_NAME="gourmand-db"

cyan() { printf '\033[0;36m[gourmand-tenant] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[gourmand-tenant] WARN: %s\033[0m\n' "$*"; }
fail() { printf '\033[0;31m[gourmand-tenant] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck source=../verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/../verify/lib-live-tenant.sh"

# ── 0) endpoints + app identity from the running stack ───────────────────────
kong_port="$(_lt_host_port mini-baas-kong 8000/tcp)"
tc_port="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
[[ -n "${kong_port}" && -n "${tc_port}" ]] || fail "mini-baas stack not running"
KONG_URL="http://127.0.0.1:${kong_port}"
TC_URL="http://127.0.0.1:${tc_port}"
SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
ANON_KEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "stack secrets not found"

APP_KEY="${BAAS_API_KEY:-$(sed -n 's/^VITE_BAAS_API_KEY=//p' "${APP_ENV_FILE}" 2>/dev/null | head -1)}"
[[ "${APP_KEY}" == mbk_* ]] || fail "no tenant API key (set BAAS_API_KEY or VITE_BAAS_API_KEY in ${APP_ENV_FILE})"
vbody="{\"key\":\"${APP_KEY}\"}"
svc_auth POST /v1/keys/verify "${vbody}"
verify=$(curl -fsS -X POST "${TC_URL}/v1/keys/verify" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "${vbody}") || fail "tenant-control unreachable"
echo "${verify}" | grep -q '"valid":true' || fail "app key invalid: ${verify}"
TENANT="$(echo "${verify}" | _lt_json_field tenant_id)"
cyan "app key → tenant '${TENANT}'"

# ── 1) resolve the client DSN (never logged in full) ─────────────────────────
env_dsn() { # $1 var name → value from the vite-gourmand backend env
  sed -n "s/^$1=//p" "${VG_ENV_FILE}" 2>/dev/null | head -1 | tr -d '"' | tr -d "'"
}
DSN="${GOURMAND_DB_DSN:-}"
DSN_SOURCE="GOURMAND_DB_DSN"
if [[ -z "${DSN}" ]]; then
  DSN="$(env_dsn DIRECT_URL)"; DSN_SOURCE="Back/.env DIRECT_URL"
fi
if [[ -z "${DSN}" ]]; then
  DSN="$(env_dsn DATABASE_URL)"; DSN_SOURCE="Back/.env DATABASE_URL"
  if [[ "${DSN}" == *":6543/"* ]]; then
    warn "DATABASE_URL targets the 6543 transaction pooler — rewriting to 5432 (prepared statements need session mode)"
    DSN="${DSN/:6543\//:5432\/}"
  fi
fi
if [[ -z "${DSN}" ]]; then
  warn "no Supabase DSN found — falling back to vite-gourmand's LOCAL compose postgres"
  warn "for the real thing run:  cd apps/vite-gourmand && make secrets   (Bitwarden, interactive)"
  vg_pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "${REPO_ROOT}/apps/vite-gourmand/.env" 2>/dev/null | head -1)"
  [[ -n "${vg_pw}" ]] || fail "no DSN anywhere: set GOURMAND_DB_DSN, or run vite-gourmand's 'make secrets', or start its local stack"
  DSN="postgres://postgres:${vg_pw}@host.docker.internal:5432/vite_gourmand"
  DSN_SOURCE="local compose fallback"
fi
# Supabase requires TLS: make the opt-in explicit so the rustls branch engages.
if [[ "${DSN}" == *"supabase.co"* || "${DSN}" == *"supabase.com"* ]]; then
  if [[ "${DSN}" != *"sslmode="* ]]; then
    [[ "${DSN}" == *"?"* ]] && DSN="${DSN}&sslmode=require" || DSN="${DSN}?sslmode=require"
    cyan "appended sslmode=require (Supabase mandates TLS)"
  fi
  [[ "${DSN}" == *":6543/"* ]] && fail "refusing the 6543 transaction pooler — use the 5432 session/direct connection"
fi
DSN_HOST="$(printf '%s' "${DSN}" | sed -E 's|.*@([^:/?]+).*|\1|')"
cyan "DSN source: ${DSN_SOURCE} (host ${DSN_HOST})"

# ── 2) register the tenant_owned mount under the app tenant ──────────────────
DB_ID=""
if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
  DB_ID="${GOURMAND_DB_ID:-}"
fi
if [[ -n "${DB_ID}" ]]; then
  probe=$(curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/${DB_ID}/schema" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${APP_KEY}")
  if [[ "${probe}" == "200" ]]; then
    cyan "reusing existing mount ${DB_ID}"
  else
    DB_ID=""
  fi
fi
if [[ -z "${DB_ID}" ]]; then
  cyan "registering mount '${MOUNT_NAME}' (isolation: tenant_owned)"
  code=$(curl -s -o /tmp/gourmand-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"postgresql\",\"name\":\"${MOUNT_NAME}\",\"connection_string\":\"${DSN}\",\"isolation\":\"tenant_owned\"}")
  if [[ "${code}" == "201" ]]; then
    DB_ID="$(_lt_json_field id < /tmp/gourmand-mount.json)"
  elif [[ "${code}" == "409" ]]; then
    cyan "mount name exists — resolving its id from the registry"
    DB_ID=$(curl -fsS "${KONG_URL}/admin/v1/databases" \
      -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" \
      | python3 -c "import json,sys; rows=json.load(sys.stdin); print(next(r['id'] for r in rows if r.get('name')=='${MOUNT_NAME}' and r.get('tenant_id')=='${TENANT}'))")
  else
    fail "mount register (${code}): $(cat /tmp/gourmand-mount.json)"
  fi
  [[ -n "${DB_ID}" ]] || fail "no mount id"
fi

# ── 3) introspection assert: their real schema, through the real gateway ─────
cyan "introspecting the client schema through the gateway"
schema=$(curl -fsS "${KONG_URL}/query/v1/${DB_ID}/schema" \
  -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${APP_KEY}") \
  || fail "schema introspection failed — check the DSN (TLS? network egress? credentials?)"
tables=$(printf '%s' "${schema}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['tables']))")
[[ "${tables}" -ge 40 ]] || fail "expected ≥40 tables in the vite-gourmand schema, saw ${tables} — wrong database?"
for headline in Order Menu Dish WorkingHours SupportTicket TimeOffRequest UserAddress Event KanbanColumn; do
  printf '%s' "${schema}" | grep -q "\"name\":\"${headline}\"" \
    || fail "headline table \"${headline}\" missing from introspection"
done
cyan "schema OK: ${tables} tables incl. Order/Menu/Dish/WorkingHours/SupportTicket/TimeOffRequest/UserAddress/Event/KanbanColumn"

# ── 4) state file (no secret material — the DSN lives encrypted in the
#       registry and in vite-gourmand's own Back/.env) ────────────────────────
cat > "${STATE_ENV}" <<EOF
# generated by scripts/seed/gourmand-tenant.sh — $(date -Iseconds)
GOURMAND_TENANT_SLUG=${TENANT}
GOURMAND_DB_ID=${DB_ID}
GOURMAND_MOUNT_NAME=${MOUNT_NAME}
GOURMAND_DSN_SOURCE=${DSN_SOURCE}
GOURMAND_DSN_HOST=${DSN_HOST}
GOURMAND_KONG_URL=${KONG_URL}
GOURMAND_TABLE_COUNT=${tables}
EOF
chmod 600 "${STATE_ENV}"
cyan "OK — mount ${DB_ID} (tenant_owned) over ${DSN_HOST}; state → ${STATE_ENV}"
