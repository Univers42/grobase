#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m165-contract-provision.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dev.pro.photo@gmail.com>         +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/21 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/21 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# m165 — the generic contract provisioner provisions an app from ONLY its contract.
# Proves: grobase is the generic factory (no app hardcode in src/), and
# provision-contract.sh creates the app's own DB + tenant + key + read_scoped mount
# + schema + frontend config, idempotently. Needs the stack up (make up).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONTRACT="infra/config/contracts/_smoke.json"
PG_CTN="${PG_CONTAINER:-mini-baas-postgres}"
OUT="${REPO}/build/contracts-smoke.env"
PASS=0; FAIL=0

ok() { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

ctn_env() { docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep "^$2=" | head -1 | cut -d= -f2-; }
ctn_port() { docker port "$1" "$2" 2>/dev/null | head -1 | sed 's/.*://'; }
pg_q() { docker exec -i -e PGPASSWORD="${PG_PASS}" "${PG_CTN}" psql -U "${PG_USER}" -d "$1" -tA -v ON_ERROR_STOP=1; }

cleanup() {
  [ -n "${SERVICE_KEY:-}" ] && [ -n "${DB_ID:-}" ] && \
    curl -s -o /dev/null -X DELETE "${KONG_URL}/admin/v1/databases/${DB_ID}" \
      -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: smoke" || true
  printf 'DROP DATABASE IF EXISTS "smoke";' | pg_q postgres >/dev/null 2>&1 || true
  rm -f "${OUT}" 2>/dev/null || true
}
trap cleanup EXIT
cd "${REPO}" || exit 1

echo "[1/3] grobase is generic — no app-specific hardcode in src/"
if grep -rIiE 'vault42|grobase-website|\bnimbus\b|\bcanagrou\b' src/ >/dev/null 2>&1; then
  bad "app name leaked into grobase src/ (factory must stay generic)"
  grep -rIiEl 'vault42|grobase-website|\bnimbus\b|\bcanagrou\b' src/ | head
else
  ok "src/ has zero app references (generic factory)"
fi

echo "[2/3] provision the smoke app from ONLY its contract"
docker ps --format '{{.Names}}' | grep -q mini-baas-kong || { echo "  ✗ stack not up (run: make up)"; exit 1; }
PG_USER="$(ctn_env "${PG_CTN}" POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
PG_PASS="$(ctn_env "${PG_CTN}" POSTGRES_PASSWORD)"; PG_PASS="${PG_PASS:-postgres}"
KONG_URL="http://127.0.0.1:$(ctn_port mini-baas-kong 8000/tcp)"
SERVICE_KEY="$(ctn_env mini-baas-kong KONG_SERVICE_API_KEY)"
bash scripts/provision-contract.sh "${CONTRACT}" || { echo "  ✗ provisioner failed"; exit 1; }

echo "[3/3] assert the provisioned state"
# database created
[ "$(printf "SELECT 1 FROM pg_database WHERE datname='smoke';" | pg_q postgres)" = "1" ] \
  && ok "database 'smoke' created" || bad "database 'smoke' missing"
# mount registered + id resolvable
DB_ID="$(curl -s "${KONG_URL}/admin/v1/databases" -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: smoke" | jq -r '.[]?|select(.name=="smoke-pg")|.id' | head -1)"
[ -n "${DB_ID}" ] && ok "mount smoke-pg registered (${DB_ID})" || bad "mount smoke-pg not registered"
# read_scoped set
[ "$(printf "SELECT read_scoped FROM public.tenant_databases WHERE id='%s';" "${DB_ID}" | pg_q postgres)" = "t" ] \
  && ok "read_scoped=true on the mount" || bad "read_scoped not set"
# schema applied into the smoke DB
[ "$(printf "SELECT to_regclass('public.smoke_notes') IS NOT NULL;" | pg_q smoke)" = "t" ] \
  && ok "schema applied (smoke_notes exists in 'smoke')" || bad "schema not applied"
# frontend config emitted with resolved tokens
if [ -f "${OUT}" ] && grep -q "PUBLIC_API_KEY=mbk_" "${OUT}" && grep -q "PUBLIC_DB_ID=${DB_ID}" "${OUT}" && grep -q "PUBLIC_TENANT_ID=smoke" "${OUT}"; then
  ok "frontend config emitted with live tokens"
else
  bad "frontend config missing/unresolved"; [ -f "${OUT}" ] && cat "${OUT}"
fi
# idempotent re-run + key reuse
KEY1="$(grep PUBLIC_API_KEY= "${OUT}" | cut -d= -f2-)"
bash scripts/provision-contract.sh "${CONTRACT}" >/dev/null 2>&1 || bad "re-run failed (not idempotent)"
KEY2="$(grep PUBLIC_API_KEY= "${OUT}" | cut -d= -f2-)"
[ -n "${KEY1}" ] && [ "${KEY1}" = "${KEY2}" ] && ok "idempotent re-run reuses the key" || bad "re-run changed the key"

echo "──────── m165: ${PASS} passed, ${FAIL} failed ────────"
[ "${FAIL}" -eq 0 ] && echo "✅ m165 PASS — generic contract provisioning works end-to-end" || { echo "✗ m165 FAIL"; exit 1; }
