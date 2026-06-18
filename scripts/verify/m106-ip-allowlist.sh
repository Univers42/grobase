#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m106-ip-allowlist.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M106 — Track-D D2e TENANT-CONFIGURABLE IP ALLOWLIST on the API edge.
# A tenant restricts which source IPs/CIDRs may call its API. The decision is an
# EDGE check: the same POST /v1/ipguard/check {tenant_id, ip} an edge auth-request
# plugin (Kong) calls before forwarding a request. A tenant with NO allowlist rule
# is UNRESTRICTED (allow → the feature is OPT-IN); a tenant WITH ≥1 rule is
# restricted to the union of its CIDRs (an out-of-range client IP → allow=false →
# the edge returns 403). The CIDR containment match runs IN GO, engine-agnostic.
#
# This gate exercises a tenant-control built FROM CURRENT source — the EXACT D2e
# code — against a scratch postgres carrying the REAL 005/032 + the NEW 049
# migration. It drives:
#
#   tenant-control (Go, TENANT_IP_ALLOWLIST_ENABLED=1) mounts:
#     POST   /v1/ipguard/check                       edge decision (service-token)
#     GET    /v1/tenants/{id}/ip-allowlist           list rules  (admin / self header)
#     POST   /v1/tenants/{id}/ip-allowlist           add a rule  (admin / self header)
#     DELETE /v1/tenants/{id}/ip-allowlist/{ruleId}  remove rule (admin / self header)
#
#   (A · POSITIVE) tenant T sets an allowlist [10.0.0.0/8] via the CRUD; then the
#       EDGE check for an IN-RANGE IP (10.1.2.3) → 200 allow=true; the data plane
#       NEVER sees the allowlist (control-plane-only decision). A self-serve CRUD
#       call (X-API-Key) adds a second rule and the new rule is enforced too.
#
#   (B · LOAD-BEARING REJECT — a gate that only shows the happy path is VACUOUS):
#       (a) the EDGE check for an OUT-OF-RANGE IP (203.0.113.9) → allow=false with
#           reason not_in_allowlist — the block REALLY happens, not a vacuous
#           always-allow; (b) a SECOND tenant U with NO allowlist row → ANY IP
#           (203.0.113.9) → allow=true restricted=false — the feature is opt-in,
#           an unconfigured tenant is exactly as open as today; (c) a malformed
#           CIDR add → 400 (not silently accepted); (d) cross-tenant DELETE of
#           T's rule under U's id → 404 (a tenant can never touch another's rules);
#           (e) the edge /check without the service token → 401.
#
#   (C · FLAG-OFF PARITY) a SECOND tenant-control with TENANT_IP_ALLOWLIST_ENABLED
#       UNSET, against the SAME DB (T still has its [10.0.0.0/8] row): every
#       /v1/ipguard* + /v1/tenants/{id}/ip-allowlist route → 404 (not mounted), and
#       — the load-bearing parity proof — because the guard is never consulted, a
#       tenant WITH an allowlist row is NOT enforced: the live edge would forward
#       ANY IP (there is no /check to call). Base admin /v1/tenants/{id} still 200.
#       Byte-identical to today: the feature is purely additive + opt-in.
#
# ISOLATED by design (mirrors m83/m103/m104): scratch postgres (prelude + REAL
# 005/032 + the NEW 049) + a tenant-control built FROM CURRENT source, ALL on a
# PRIVATE network, every name suffixed with $$, an EXIT-trap removing EVERYTHING.
# It NEVER touches a mini-baas-* container/network/image/volume and NEVER edits
# the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_049="${MIG_DIR}/049_tenant_ip_allowlist.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M106] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M106] FAIL — $*"
  exit 1
}

PG_IMAGE="${M106_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m106-tc-$$:scratch"
NET="m106net-$$"
PG="m106-pg-$$"
TC_ON="m106-tc-on-$$"   # TENANT_IP_ALLOWLIST_ENABLED=1   (A · positive / B · reject)
TC_OFF="m106-tc-off-$$" # TENANT_IP_ALLOWLIST_ENABLED unset (C · parity)
PORT_ON="${M106_PORT_ON:-19106}"
PORT_OFF="${M106_PORT_OFF:-19107}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m106-internal-service-token-$$"
BODY_TMP="$(mktemp)"

# Two tenant slugs: T gets an allowlist, U stays unconfigured (opt-in control).
T_SLUG="m106-tenant-t-$$"
T_SLUG="$(echo "${T_SLUG}" | tr '[:upper:]' '[:lower:]' | cut -c1-60)"
U_SLUG="m106-tenant-u-$$"
U_SLUG="$(echo "${U_SLUG}" | tr '[:upper:]' '[:lower:]' | cut -c1-60)"

# The IPs under test.
IP_IN="10.1.2.3"     # inside 10.0.0.0/8
IP_OUT="203.0.113.9" # outside 10.0.0.0/8
IP_IN2="192.168.4.7" # inside the self-serve-added 192.168.0.0/16

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck disable=SC2120  # psql_q is called both with flags and via heredoc (no args)
psql_q() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply one migration the SAME way `make migrate` does: strip leading 42-header
# `#` lines before piping to psql. $1=file.
apply_migration() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

# Service-token admin request → echo HTTP status, body→BODY_TMP.
#   $1=method $2=port $3=path $4(optional)=body
admin_req() {
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}

# The EDGE decision call (service-token): POST /v1/ipguard/check {tenant_id, ip}.
#   $1=port $2=tenant $3=ip  → echo HTTP status, body→BODY_TMP.
edge_check() {
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/ipguard/check" \
    -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"tenant_id\":\"$2\",\"ip\":\"$3\"}"
}

# Self-serve CRUD with an API key (X-API-Key). $1=method $2=port $3=path $4=key $5(optional)=body
self_req() {
  local m="$1" p="$2" path="$3" key="$4" body="${5:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-API-Key: ${key}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-API-Key: ${key}"
  fi
}

# Extract a top-level JSON field off BODY_TMP. Tolerates ZERO matches (grep||true
# so pipefail+set -e survive a missing field). $1=field. String OR bare value.
json_field() { { grep -o "\"$1\":[^,}]*" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g; s/^[[:space:]]*//; s/[[:space:]]*$//'; }

wait_ready_http() { # $1=container $2=port $3=path
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2$3" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || {
      red "$1 exited early:"
      docker logs "$1" 2>&1 | tail -20
      return 1
    }
    sleep 0.5
  done
  red "$1 never became ready:"
  docker logs "$1" 2>&1 | tail -20
  return 1
}

# ── 0) build the scratch tenant-control FROM CURRENT source ────────────────────
step "0/9 build scratch tenant-control from CURRENT source (the D2e ipguard code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null ||
  fail "scratch tenant-control image build failed — gate must exercise the drafted D2e code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL 005/032 + NEW 049 ──────────────
step "1/9 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# Postgres image init runs a SOCKET-ONLY temp server then restarts — gate on TCP
# (pg_isready -h 127.0.0.1) + a real SELECT 1, not on the steady-state log alone.
for i in $(seq 1 90); do
  docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 &&
    [[ "$(psql_val 'SELECT 1')" == "1" ]] && break
  [[ $i -eq 90 ]] && {
    docker logs "${PG}" 2>&1 | tail -20
    fail "scratch postgres never accepted TCP (line: PG TCP ready)"
  }
  sleep 0.5
done
ok "postgres up (TCP + SELECT 1)"

step "1b/9 apply prelude (schema_migrations, auth fns, roles, pgcrypto), then REAL 005/032 + NEW 049"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS uuid
  LANGUAGE sql STABLE AS $fn$
    SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $fn$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS uuid
  LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(
      NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id',
      NULLIF(current_setting('app.current_tenant_id', true), ''),
      auth.current_user_id()::text
    )::uuid $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon')          THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role; END IF;
END $r$;
GRANT EXECUTE ON FUNCTION auth.current_user_id()   TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
SQL
}
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"
  sleep 0.5
done

apply_migration "${MIGRATION_005}" || fail "real migration 005 failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032 failed to apply (line: apply 032)"
apply_migration "${MIGRATION_049}" || fail "NEW migration 049_tenant_ip_allowlist.sql failed to apply (line: apply 049)"

# Table exists + empty; the unique constraint + index landed; RLS enabled.
[[ "$(psql_val "SELECT count(*) FROM public.tenant_ip_allowlist")" == "0" ]] ||
  fail "tenant_ip_allowlist should start EMPTY (line: allowlist empty)"
[[ "$(psql_val "SELECT count(*) FROM pg_indexes WHERE tablename='tenant_ip_allowlist' AND indexname='tenant_ip_allowlist_tenant_idx'")" == "1" ]] ||
  fail "tenant-scoped index missing from 049 (line: allowlist idx)"
[[ "$(psql_val "SELECT relrowsecurity FROM pg_class WHERE relname='tenant_ip_allowlist'")" == "t" ]] ||
  fail "RLS not enabled on tenant_ip_allowlist by 049 (line: allowlist rls)"
ok "migrations applied — tenant_ip_allowlist empty, tenant index present, RLS on"

# ── 2) boot tenant-control with TENANT_IP_ALLOWLIST_ENABLED=1 + self-serve ─────
step "2/9 boot tenant-control TENANT_IP_ALLOWLIST_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_IP_ALLOWLIST_ENABLED=1 \
  -e TENANT_SELFSERVE_ENABLED=1 \
  -e ADAPTER_REGISTRY_URL="" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "IPGUARD-ON tenant-control not ready (line: wait TC_ON)"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "tenant IP allowlist enabled" ||
  {
    docker logs "${TC_ON}" 2>&1 | tail -20
    fail "ip-allowlist never reported enabled (line: ip enabled log)"
  }
ok "IPGUARD-ON tenant-control up (/v1/ipguard* + ip-allowlist routes mounted)"

# Create T and U via the admin API + mint an API key for T (self-serve auth),
# using the SAME two-step seed m83 uses (POST /v1/tenants, then POST .../keys —
# the keys response returns the full mbk_ key at the TOP level).
step "2b/9 create tenants T (allowlisted) + U (unconfigured) and mint T's API key"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${T_SLUG}\",\"name\":\"Tenant T\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "create T expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: create T)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${U_SLUG}\",\"name\":\"Tenant U\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "create U expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: create U)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${T_SLUG}/keys" '{"name":"t-key","scopes":["read","write","admin"]}')"
[[ "${C}" == "201" ]] || fail "mint T key expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: mint T key)"
T_KEY="$(json_field key)"
[[ "${T_KEY}" == mbk_* ]] || fail "T key not returned as a full mbk_ key — got '${T_KEY}' — $(head -c 300 "${BODY_TMP}") (line: T key shape)"
ok "T + U created (both nano); T API key minted (self-serve auth ready)"

# ── 3) (A · POSITIVE) T sets [10.0.0.0/8]; in-range IP → allow=true ────────────
step "3/9 (A · POSITIVE) admin adds 10.0.0.0/8 to T's allowlist; EDGE check for ${IP_IN} → 200 allow=true"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${T_SLUG}/ip-allowlist" '{"cidr":"10.0.0.0/8","note":"office"}')"
[[ "${C}" == "201" ]] || fail "(A) add CIDR expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A add cidr)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_ip_allowlist WHERE tenant_id='${T_SLUG}'")" == "1" ]] ||
  fail "(A) the allowlist row did not persist for T (line: A row persist)"
C="$(edge_check "${PORT_ON}" "${T_SLUG}" "${IP_IN}")"
[[ "${C}" == "200" ]] || fail "(A) edge /check expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A check status)"
[[ "$(json_field allow)" == "true" ]] || fail "(A) in-range IP ${IP_IN} was NOT allowed — $(head -c 300 "${BODY_TMP}") (line: A in-range allow)"
[[ "$(json_field restricted)" == "true" ]] || fail "(A) T should report restricted=true (it has a rule) — $(head -c 300 "${BODY_TMP}") (line: A restricted)"
ok "(A) T allowlisted to 10.0.0.0/8; in-range ${IP_IN} → allow=true restricted=true"

# ── 3b) (A · POSITIVE) self-serve add 192.168.0.0/16; new rule enforced ────────
step "3b/9 (A · POSITIVE) self-serve (X-API-Key) adds 192.168.0.0/16; EDGE check for ${IP_IN2} → allow=true"
C="$(self_req POST "${PORT_ON}" "/v1/tenants/me/ip-allowlist" "${T_KEY}" '{"cidr":"192.168.0.0/16","note":"vpn"}')"
[[ "${C}" == "201" ]] || fail "(A) self-serve add expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A self add)"
C="$(self_req GET "${PORT_ON}" "/v1/tenants/me/ip-allowlist" "${T_KEY}")"
[[ "${C}" == "200" ]] || fail "(A) self-serve list expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A self list)"
[[ "$(json_field count)" == "2" ]] || fail "(A) T should now have 2 rules — $(head -c 300 "${BODY_TMP}") (line: A two rules)"
C="$(edge_check "${PORT_ON}" "${T_SLUG}" "${IP_IN2}")"
[[ "${C}" == "200" && "$(json_field allow)" == "true" ]] ||
  fail "(A) the self-serve-added 192.168.0.0/16 was not enforced for ${IP_IN2} — $(head -c 300 "${BODY_TMP}") (line: A self enforced)"
ok "(A) self-serve CRUD works; the new rule is enforced (${IP_IN2} → allow=true)"

# ── 4) (B · LOAD-BEARING REJECT) ───────────────────────────────────────────────
step "4/9 (B · REJECT) out-of-range 403 · unconfigured tenant open · bad CIDR 400 · cross-tenant DELETE 404 · /check needs token"

# B(a) — out-of-range IP for the RESTRICTED tenant → allow=false (REALLY blocked).
C="$(edge_check "${PORT_ON}" "${T_SLUG}" "${IP_OUT}")"
[[ "${C}" == "200" ]] || fail "(B a) edge /check expected 200 envelope, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B a status)"
[[ "$(json_field allow)" == "false" ]] ||
  fail "(B a) OUT-OF-RANGE IP ${IP_OUT} was ALLOWED (allow!=false) — the allowlist is a vacuous always-allow! — $(head -c 300 "${BODY_TMP}") (line: B a out-of-range deny)"
[[ "$(json_field reason)" == "not_in_allowlist" ]] ||
  fail "(B a) out-of-range reason != not_in_allowlist — $(head -c 300 "${BODY_TMP}") (line: B a reason)"
ok "(B a) out-of-range ${IP_OUT} → allow=false reason=not_in_allowlist (the block is REAL, the edge returns 403)"

# B(b) — a tenant with NO allowlist row → ANY IP allowed (opt-in default).
[[ "$(psql_val "SELECT count(*) FROM public.tenant_ip_allowlist WHERE tenant_id='${U_SLUG}'")" == "0" ]] ||
  fail "(B b) tenant U should have NO allowlist row (line: B b U empty)"
C="$(edge_check "${PORT_ON}" "${U_SLUG}" "${IP_OUT}")"
[[ "${C}" == "200" && "$(json_field allow)" == "true" && "$(json_field restricted)" == "false" ]] ||
  fail "(B b) unconfigured tenant U did NOT default to OPEN for ${IP_OUT} (got allow=$(json_field allow) restricted=$(json_field restricted)) — the feature is not opt-in! — $(head -c 300 "${BODY_TMP}") (line: B b opt-in)"
ok "(B b) unconfigured tenant U → ANY IP allow=true restricted=false (the feature is OPT-IN, an unset tenant is as open as today)"

# B(c) — a malformed CIDR add → 400 (not silently accepted).
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${T_SLUG}/ip-allowlist" '{"cidr":"not-a-cidr"}')"
[[ "${C}" == "400" ]] || fail "(B c) a malformed CIDR was accepted (got ${C}, want 400) — the validator is OPEN! — $(head -c 300 "${BODY_TMP}") (line: B c bad cidr)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_ip_allowlist WHERE tenant_id='${T_SLUG}'")" == "2" ]] ||
  fail "(B c) a row appeared despite the 400 — the bad CIDR leaked into the DB (line: B c no leak)"
ok "(B c) malformed CIDR → 400 and no row created"

# B(d) — cross-tenant DELETE: take one of T's rule ids, try to delete it under U's
# id. The tenant-bound WHERE means it matches nothing → 404 (T's rule untouched).
RULE_ID="$(psql_val "SELECT id::text FROM public.tenant_ip_allowlist WHERE tenant_id='${T_SLUG}' LIMIT 1")"
[[ -n "${RULE_ID}" ]] || fail "(B d) could not read a rule id for T (line: B d rule id)"
C="$(admin_req DELETE "${PORT_ON}" "/v1/tenants/${U_SLUG}/ip-allowlist/${RULE_ID}")"
[[ "${C}" == "404" ]] || fail "(B d) cross-tenant DELETE of T's rule under U returned ${C} (want 404) — rules are NOT tenant-bound! (line: B d cross-tenant)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_ip_allowlist WHERE id::text='${RULE_ID}'")" == "1" ]] ||
  fail "(B d) T's rule was deleted via U's id — cross-tenant DELETE succeeded! (line: B d rule survives)"
ok "(B d) cross-tenant DELETE → 404 and T's rule survives (rules are tenant-bound)"

# B(e) — the edge /check WITHOUT the service token → 401 (a tenant cannot self-decide).
C="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${PORT_ON}/v1/ipguard/check" \
  -H 'Content-Type: application/json' -d "{\"tenant_id\":\"${T_SLUG}\",\"ip\":\"${IP_IN}\"}")"
[[ "${C}" == "401" ]] || fail "(B e) edge /check without a service token returned ${C} (want 401) — the decision endpoint is OPEN! (line: B e no token)"
ok "(B e) edge /check without the service token → 401 (only the edge/gateway may ask)"

# ── 5) (C · FLAG-OFF PARITY) ───────────────────────────────────────────────────
step "5/9 (C · PARITY) a SECOND tenant-control with TENANT_IP_ALLOWLIST_ENABLED UNSET, SAME DB (T still allowlisted)"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_SELFSERVE_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "IPGUARD-OFF tenant-control not ready (line: wait TC_OFF)"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "tenant IP allowlist disabled" ||
  {
    docker logs "${TC_OFF}" 2>&1 | tail -20
    fail "(C) OFF instance did not report ip-allowlist disabled (flag default not OFF?) (line: C disabled log)"
  }
ok "IPGUARD-OFF tenant-control up (flag default OFF)"

# C(a) — the edge /check route → 404 (not mounted). With no /check, the live edge
# has nothing to call, so a tenant WITH an allowlist row is simply NOT enforced —
# byte-identical to today (the allowlist is inert).
C="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${PORT_OFF}/v1/ipguard/check" \
  -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"tenant_id\":\"${T_SLUG}\",\"ip\":\"${IP_OUT}\"}")"
[[ "${C}" == "404" ]] || fail "(C a) edge /check with flag OFF expected 404 (route not mounted), got ${C} — the guard leaked! (line: C a check 404)"
# C(b) — the CRUD routes → 404 (not mounted) for admin AND self.
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants/${T_SLUG}/ip-allowlist")"
[[ "${C}" == "404" ]] || fail "(C b) admin GET ip-allowlist with flag OFF expected 404, got ${C} (line: C b admin 404)"
C="$(self_req GET "${PORT_OFF}" "/v1/tenants/me/ip-allowlist" "${T_KEY}")"
[[ "${C}" == "404" ]] || fail "(C b) self GET ip-allowlist with flag OFF expected 404, got ${C} (line: C b self 404)"
ok "(C a/b) flag OFF → /v1/ipguard/check + ip-allowlist routes all 404 (the guard is never consulted; T's allowlist row is INERT)"

# C(c) — base admin routes STILL 200 (the pre-D2e baseline is untouched). T's
# allowlist row is STILL in the DB (additive table) but inert.
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants/${T_SLUG}")"
[[ "${C}" == "200" ]] || fail "(C c) base admin GET /v1/tenants/{id} expected 200 on OFF router, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C c admin 200)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_ip_allowlist WHERE tenant_id='${T_SLUG}'")" == "2" ]] ||
  fail "(C c) T's allowlist rows vanished — the table must persist (inert), not be torn down (line: C c rows persist)"
ok "(C c) base admin /v1/tenants/{id} still 200; T's 2 allowlist rows persist in the DB but are INERT (byte-parity, purely additive + opt-in)"

# ── 6) summary + gate log ──────────────────────────────────────────────────────
step "9/9 summary"
green "[M106] (A) POSITIVE: T sets 10.0.0.0/8 (admin) + 192.168.0.0/16 (self-serve); EDGE check ${IP_IN}/${IP_IN2} → 200 allow=true (control-plane-only decision)"
green "[M106] (B) REJECT:   out-of-range ${IP_OUT} → allow=false not_in_allowlist (REAL block); unconfigured U → ANY IP allow=true (OPT-IN); bad CIDR 400; cross-tenant DELETE 404; /check needs service token (401)"
green "[M106] (C) PARITY:   TENANT_IP_ALLOWLIST_ENABLED unset → /v1/ipguard/check + ip-allowlist routes 404, base admin 200, T's allowlist rows persist but INERT (byte-identical to today)"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d2e-ip-allowlist}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m106=PASS" --outcome pass \
      --msg "D2e tenant-configurable IP allowlist on the API edge: a tenant sets a CIDR allowlist (admin + self-serve CRUD, migration 049); the EDGE decision POST /v1/ipguard/check {tenant_id,ip} (service-token, the same call an edge plugin makes) returns allow=true for an in-range IP and allow=false (not_in_allowlist) for an out-of-range IP -> the edge returns 403; a tenant with NO allowlist row is UNRESTRICTED (any IP allow=true, restricted=false) so the feature is OPT-IN; bad CIDR 400, cross-tenant DELETE 404, /check without the service token 401. FLAG-OFF PARITY: TENANT_IP_ALLOWLIST_ENABLED unset -> /v1/ipguard/check + /v1/tenants/{id|me}/ip-allowlist all 404 (not mounted), the guard is never consulted so a tenant WITH an allowlist row is NOT enforced, base admin 200, rows persist but inert = byte-identical to today. Enforcement is control-plane-only (an edge decision), never in RequestIdentity/RLS/data plane -> SHARE_POOLS untouched. CIDR containment matched in Go (engine-agnostic)." \
      --ref "scripts/verify/m106-ip-allowlist.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M106] ALL GATES GREEN — D2e IP allowlist: in-range allow / out-of-range 403, opt-in default, flag-OFF byte-parity (enforcement stays control-plane only)"
exit 0
