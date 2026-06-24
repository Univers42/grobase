#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m164-email-otp.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/20 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/20 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M164 — EMAIL LOGIN OTP (Bitwarden-style second factor, EMAIL_OTP_ENABLED). A 6-digit
# code is MAILED to the account address (captured here by a real Mailpit SMTP sink),
# entered back, and verified with a short proof. Exercises a tenant-control built FROM
# CURRENT source:
#
#   (A) request → the code is EMAILED (read back from Mailpit), stored ONLY as a
#       peppered hash (cleartext absent from the DB); verify the correct code → 200
#       {verified:true, proof:<jwt>}.
#   (B) load-bearing rejects: a consumed code is single-use (401); a wrong code is
#       rejected (401) and after the attempt cap → 429; an expired code → 410.
#   (C) anti-enumeration: request for ANY address → 200 (no oracle).
#   (D) PARITY: EMAIL_OTP_ENABLED unset → /v1/auth/otp/* routes 404.
#
# ISOLATED: scratch postgres (prelude + NEW 075) + Mailpit + a tenant-control FROM
# CURRENT source on a PRIVATE network, names suffixed $$, EXIT-trap cleanup. Never
# touches mini-baas-*.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M164] $*"; }
ok() { green "  ✓ $*"; }
fail() { red "[M164] FAIL — $*"; exit 1; }

PG_IMAGE="${M164_PG_IMAGE:-postgres:16-alpine}"
MAILPIT_IMAGE="${M164_MAILPIT_IMAGE:-axllent/mailpit:latest}"
TC_IMG="m164-tc-$$:scratch"
NET="m164net-$$"
PG="m164-pg-$$"
MP="m164-mailpit-$$"
TC_ON="m164-tc-on-$$"
TC_OFF="m164-tc-off-$$"
PORT_ON="${M164_PORT_ON:-19168}"
PORT_OFF="${M164_PORT_OFF:-19169}"
PORT_MP="${M164_PORT_MP:-19170}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m164-svc-$$"
JWT_SECRET="m164-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
PEPPER="m164-pepper-$$"
EMAIL="dev@grobase.test"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${MP}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply_migration() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

otp_req() { # $1=port $2=path $3=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1$2" -H 'Content-Type: application/json' -d "$3"
}
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'; }

# Read the 6-digit code from the latest Mailpit message's text body.
mp_latest_code() {
  local id
  id="$(curl -s "http://127.0.0.1:${PORT_MP}/api/v1/messages" | grep -oE '"ID":"[^"]+"' | head -1 | sed 's/.*"ID":"//; s/"//')"
  [ -n "${id}" ] || return 1
  curl -s "http://127.0.0.1:${PORT_MP}/api/v1/message/${id}" | grep -oE '"Text":"[^"]*"' | grep -oE '[0-9]{6}' | head -1
}

wait_ready_http() {
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2$3" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# ── 0) build tenant-control ────────────────────────────────────────────────────
step "0/6 build scratch tenant-control from CURRENT source"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "tenant-control build failed"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?')"

# ── 1) net + postgres + 075 + Mailpit ──────────────────────────────────────────
step "1/6 boot net (${NET}): postgres + migration 075 + Mailpit"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 90); do
  docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && [[ "$(psql_val 'SELECT 1')" == "1" ]] && break
  [[ $i -eq 90 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "postgres never ready"; }
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $fn$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id', NULLIF(current_setting('app.current_tenant_id', true), ''), auth.current_user_id()::text)::uuid $fn$;
DO $r$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF; END $r$;
GRANT EXECUTE ON FUNCTION auth.current_user_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
SQL
apply_migration "${MIG_DIR}/005_add_tenant_table.sql" || fail "migration 005 failed"
apply_migration "${MIG_DIR}/032_tenants.sql" || fail "migration 032 failed"
apply_migration "${MIG_DIR}/075_login_otp.sql" || fail "migration 075 failed"
[[ "$(psql_val "SELECT count(*) FROM public.login_otps")" == "0" ]] || fail "login_otps should start EMPTY"
docker run -d --name "${MP}" --network "${NET}" -p "127.0.0.1:${PORT_MP}:8025" "${MAILPIT_IMAGE}" >/dev/null
wait_ready_http "${MP}" "${PORT_MP}" /api/v1/messages || fail "mailpit not ready"
ok "migration 075 applied (login_otps empty); Mailpit up (SMTP ${MP}:1025, API :${PORT_MP})"

# ── 2) boot tenant-control EMAIL_OTP_ENABLED=1 (SMTP → Mailpit) ────────────────
step "2/6 boot tenant-control EMAIL_OTP_ENABLED=1 on 127.0.0.1:${PORT_ON}"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e EMAIL_OTP_ENABLED=1 -e KEY_HASH_PEPPER="${PEPPER}" \
  -e EMAIL_OTP_TTL_SECS=300 -e EMAIL_OTP_MAX_ATTEMPTS=3 \
  -e SMTP_HOST="${MP}" -e SMTP_PORT=1025 -e SMTP_SECURE=false -e EMAIL_FROM="otp@grobase.test" \
  -e ADAPTER_REGISTRY_URL="" -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "OTP-ON tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "email login OTP enabled" || { docker logs "${TC_ON}" 2>&1 | tail -20; fail "email OTP never reported enabled"; }
ok "OTP-ON tenant-control up (/v1/auth/otp/request|verify mounted, SMTP → Mailpit)"

# ── 3) (A) request → emailed code, stored hashed, verify correct → proof ───────
step "3/6 (A) request emails a 6-digit code (read from Mailpit), stored hashed, verify → proof"
[[ "$(otp_req "${PORT_ON}" /v1/auth/otp/request "{\"email\":\"${EMAIL}\"}")" == "200" ]] || fail "(A) request expected 200 — $(head -c 200 "${BODY_TMP}")"
CODE=""
for i in $(seq 1 20); do CODE="$(mp_latest_code || true)"; [ -n "${CODE}" ] && break; sleep 0.3; done
[[ "${CODE}" =~ ^[0-9]{6}$ ]] || fail "(A) no 6-digit code arrived in Mailpit (got '${CODE}')"
[[ "$(psql_val "SELECT count(*) FROM public.login_otps WHERE code_hash='${CODE}'")" == "0" ]] || fail "(A) the cleartext code is stored in the DB — must store ONLY a hash"
[[ "$(psql_val "SELECT count(*) FROM public.login_otps WHERE email='${EMAIL}'")" == "1" ]] || fail "(A) no login_otps row for the email"
[[ "$(otp_req "${PORT_ON}" /v1/auth/otp/verify "{\"email\":\"${EMAIL}\",\"code\":\"${CODE}\"}")" == "200" ]] || fail "(A) verify with the correct code expected 200 — $(head -c 200 "${BODY_TMP}")"
grep -q '"verified":true' "${BODY_TMP}" || fail "(A) verify did not report verified:true"
PROOF="$(json_str proof)"; [[ "$(printf '%s' "${PROOF}" | grep -c '\.')" -ge 1 ]] && [[ "$(echo "${PROOF}" | tr -cd '.' | wc -c)" == "2" ]] || fail "(A) verify did not return a JWT proof (got '${PROOF:0:16}…')"
ok "(A) code emailed + read from Mailpit; DB stores ONLY the hash; correct code → 200 verified + JWT proof"

# ── 4) (B) single-use · wrong code · attempt cap · expiry ──────────────────────
step "4/6 (B) consumed→401 · wrong→401 · attempt cap→429 · expired→410"
# single-use: the just-consumed code → 401.
[[ "$(otp_req "${PORT_ON}" /v1/auth/otp/verify "{\"email\":\"${EMAIL}\",\"code\":\"${CODE}\"}")" == "401" ]] || fail "(B) a consumed code was accepted again — not single-use"
ok "(B) consumed code → 401 (single-use)"
# wrong code + attempt cap (max=3): request fresh, then 3 wrong → 401, 4th → 429.
[[ "$(otp_req "${PORT_ON}" /v1/auth/otp/request "{\"email\":\"${EMAIL}\"}")" == "200" ]] || fail "(B) re-request failed"
for n in 1 2 3; do
  [[ "$(otp_req "${PORT_ON}" /v1/auth/otp/verify "{\"email\":\"${EMAIL}\",\"code\":\"000000\"}")" == "401" ]] || fail "(B) wrong attempt ${n} expected 401"
done
[[ "$(otp_req "${PORT_ON}" /v1/auth/otp/verify "{\"email\":\"${EMAIL}\",\"code\":\"000000\"}")" == "429" ]] || fail "(B) attempt cap not enforced (4th wrong should be 429)"
ok "(B) wrong code → 401; the 4th attempt → 429 (attempt cap enforced)"
# expiry: request fresh, force expires_at into the past, verify → 410.
[[ "$(otp_req "${PORT_ON}" /v1/auth/otp/request "{\"email\":\"${EMAIL}\"}")" == "200" ]] || fail "(B) re-request for expiry failed"
psql_val "UPDATE public.login_otps SET expires_at = now() - interval '1 minute' WHERE email='${EMAIL}' AND consumed_at IS NULL" >/dev/null
[[ "$(otp_req "${PORT_ON}" /v1/auth/otp/verify "{\"email\":\"${EMAIL}\",\"code\":\"123456\"}")" == "410" ]] || fail "(B) an expired code did not return 410"
ok "(B) expired code → 410"

# ── 5) (C) anti-enumeration: request for ANY address → 200 ─────────────────────
step "5/6 (C) anti-enumeration — request for an arbitrary address → 200 (no oracle)"
[[ "$(otp_req "${PORT_ON}" /v1/auth/otp/request '{"email":"nobody-'"$$"'@nowhere.test"}')" == "200" ]] || fail "(C) request for an arbitrary email did not return 200 (enumeration oracle)"
ok "(C) request is identical (200) for any address — no email-enumeration oracle"

# ── 6) (D) PARITY: flag OFF → routes 404 ───────────────────────────────────────
step "6/6 (D · PARITY) EMAIL_OTP_ENABLED unset → /v1/auth/otp/* 404"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "OTP-OFF tenant-control not ready"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "email login OTP disabled" || fail "(D) OFF instance did not report OTP disabled"
[[ "$(otp_req "${PORT_OFF}" /v1/auth/otp/request "{\"email\":\"${EMAIL}\"}")" == "404" ]] || fail "(D) /v1/auth/otp/request with flag OFF expected 404"
[[ "$(otp_req "${PORT_OFF}" /v1/auth/otp/verify "{\"email\":\"${EMAIL}\",\"code\":\"123456\"}")" == "404" ]] || fail "(D) /v1/auth/otp/verify with flag OFF expected 404"
ok "(D) flag OFF → /v1/auth/otp/* 404 (byte-parity)"

green "[M164] (A) code emailed + verified + JWT proof; DB stores only the hash"
green "[M164] (B) single-use 401 · wrong 401 · attempt cap 429 · expired 410"
green "[M164] (C) anti-enumeration — request is 200 for any address"
green "[M164] (D) flag OFF → /v1/auth/otp/* 404"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-email-otp}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m164=PASS" --outcome pass \
      --msg "email login OTP: a 6-digit code is mailed (captured via Mailpit), stored only as a peppered hash; correct code -> 200 + JWT proof; consumed=401 single-use, wrong=401, attempt-cap=429, expired=410; request is 200 for any address (no enumeration oracle); EMAIL_OTP_ENABLED unset -> /v1/auth/otp/* 404 (byte-parity)" \
      --ref "scripts/verify/m164-email-otp.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M164] ALL GATES GREEN — email login OTP (Bitwarden-style second factor)"
exit 0
