#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m130-custom-entitlement-enforced.sh               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M130 — DYNAMIC BUILDER: a per-tenant CUSTOM entitlement is what the data plane
# is STAMPED with — NOT the named tier. THE LOAD-BEARING PROOF of the builder.
#
# A tenant is seeded on the `essential` plan. An OPERATOR (service token) mints a
# custom entitlement with a RAISED ceiling (ceiling_plan=pro, a sales deal) and a
# narrowed custom mask: {aggregate:true, transactions:false, rps:250,
# quota.query.count:5_000_000, max_mounts:3}. Three mounts of mixed engines are
# registered. The adapter-registry /connect STAMP for a mount must carry the
# CUSTOM mask (rps=250, aggregate=true, transactions=false) — proving the control
# plane resolved the EFFECTIVE per-tenant package (custom overlay clamped to the
# pro ceiling), NOT essential's tier mask (rps=200) and NOT pro's (rps=400).
#
#   tenant on plan=essential, operator ceiling_plan=pro, custom rps=250
#     adapter-registry (PACKAGE_ENFORCEMENT=1, BUILDER_ENABLED=1)
#       GET /databases/{id}/connect  →  capability_overrides:
#                                          rps=250            (NOT 200, NOT 400)
#                                          aggregate=true     (custom)
#                                          transactions=false (custom narrows pro's true)
#       3 mounts (postgresql/sqlite + a 3rd) register under max_mounts=3 (custom)
#
# NON-VACUITY (fails on today's HEAD / with BUILDER_ENABLED off): without the
# resolver swap the /connect stamp resolves essential verbatim (rps=200,
# transactions=false-by-tier but aggregate=true-by-tier), so the rps=250 assertion
# is impossible without the dynamic builder applying the custom entitlement. The
# gate ALSO boots a SECOND adapter-registry with BUILDER_ENABLED unset and asserts
# the SAME mount stamps rps=200 (the essential tier) there — the flag is the only
# difference (see also m134 for the full parity sweep).
#
# ISOLATED by design (mirrors m83/m121): scratch postgres (prelude + REAL 004 +
# 005 + 006 + 032 + 062) + tenant-control + two adapter-registry binaries built
# FROM CURRENT source, ALL on a PRIVATE network, every name suffixed $$, an
# EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-* container/network/
# image/volume and NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/go/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M130] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M130] FAIL — $*"; exit 1; }

PG_IMAGE="${M130_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m130-tc-$$:scratch"
AR_IMG="m130-ar-$$:scratch"
NET="m130net-$$"
PG="m130-pg-$$"
TC="m130-tc-$$"
AR_ON="m130-ar-on-$$"      # BUILDER_ENABLED=1  (custom stamp)
AR_OFF="m130-ar-off-$$"    # BUILDER_ENABLED unset (tier stamp = parity)
PORT_TC="${M130_PORT_TC:-18930}"
PORT_AR_ON="${M130_PORT_AR_ON:-18931}"
PORT_AR_OFF="${M130_PORT_AR_OFF:-18932}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m130-internal-service-token-$$"
ENC_KEY="m130-enc-key-0123456789abcdef0123456789abcdef"
TENANT="m130-t-$$"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${TC}" "${AR_ON}" "${AR_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" "${AR_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply_migration() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

# Admin (service-token) request → echo HTTP status, body→BODY_TMP.
admin_req() { # $1=method $2=port $3=path $4(opt)=json
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}

# adapter-registry register (service-token + tenant header) → status, body→BODY_TMP.
ar_register() { # $1=port $2=tenant $3=json
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${1}/databases" \
    -H "X-Service-Token: ${SVC_TOKEN}" -H "X-Baas-Tenant-Id: ${2}" \
    -H 'Content-Type: application/json' -d "${3}"
}
# adapter-registry connect (service-token + tenant header) → status, body→BODY_TMP.
ar_connect() { # $1=port $2=tenant $3=mountId
  curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${1}/databases/${3}/connect" \
    -H "X-Service-Token: ${SVC_TOKEN}" -H "X-Baas-Tenant-Id: ${2}"
}

# Extract the numeric value of a capability_overrides field from BODY_TMP, e.g.
# co_num rps → 250. The mask is nested under "capability_overrides":{...}; we grep
# the whole body since fields are unique enough for this gate.
co_num() { { grep -o "\"$1\":[0-9]*" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://'; }
co_bool() { { grep -o "\"$1\":\(true\|false\)" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://'; }
mount_id() { grep -o '"id":"[^"]*"' "${BODY_TMP}" | head -1 | cut -d'"' -f4; }

wait_ready() { # $1=container $2=port
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# ── 0) build scratch tenant-control + adapter-registry FROM CURRENT source ──────
step "0/8 build scratch tenant-control + adapter-registry from CURRENT source (the builder code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "tenant-control image build failed (line: build TC)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=adapter-registry --build-arg PORT=3021 \
  -t "${AR_IMG}" "${GO_DIR}" >/dev/null || fail "adapter-registry image build failed (line: build AR)"
ok "tenant-control + adapter-registry built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL 004/005/006/032/062 ─────────────
step "1/8 boot isolated net (${NET}): postgres + migrations"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready)"
  sleep 0.5
done
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS text LANGUAGE sql STABLE AS $fn$ SELECT current_setting('app.current_user_id', true) $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "prelude never committed (line: prelude)"; sleep 0.5; done
apply_migration "${MIG_DIR}/004_add_adapter_registry.sql" || fail "migration 004 failed (line: 004)"
apply_migration "${MIG_DIR}/005_add_tenant_table.sql"     || fail "migration 005 failed (line: 005)"
apply_migration "${MIG_DIR}/006_add_connection_salt.sql"  || true
apply_migration "${MIG_DIR}/032_tenants.sql"              || fail "migration 032 failed (line: 032)"
apply_migration "${MIG_DIR}/062_tenant_entitlements.sql"  || fail "migration 062 failed (line: 062)"
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_tenant_id_fkey; DROP POLICY IF EXISTS tenant_databases_owner_crud ON public.tenant_databases; DROP POLICY IF EXISTS tenant_databases_tenant_isolation ON public.tenant_databases; ALTER TABLE public.tenant_databases ALTER COLUMN tenant_id TYPE TEXT;' >/dev/null 2>&1 || fail "widen tenant_id->TEXT (004 legacy made it uuid; prod adapter-registry EnsureSchema is TEXT; AR recreates the RLS policy at boot)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_entitlements")" == "0" ]] \
  || fail "tenant_entitlements should start EMPTY (line: 062 empty)"
ok "migrations applied — tenant_databases / tenants / tenant_entitlements exist and empty"

# ── 2) boot tenant-control (TENANT_SELFSERVE_ENABLED=1 + BUILDER_ENABLED=1) ─────
step "2/8 boot tenant-control (SELFSERVE+BUILDER on) + adapter-registry-ON (BUILDER on) + adapter-registry-OFF (parity)"
docker run -d --name "${TC}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ADAPTER_REGISTRY_URL="http://${AR_ON}:3021" \
  -e TENANT_SELFSERVE_ENABLED=1 -e BUILDER_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_TC}:3020" "${TC_IMG}" >/dev/null
docker run -d --name "${AR_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e VAULT_ENC_KEY="${ENC_KEY}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e PACKAGE_ENFORCEMENT=1 -e BUILDER_ENABLED=1 -e PORT=3021 \
  -p "127.0.0.1:${PORT_AR_ON}:3021" "${AR_IMG}" >/dev/null
docker run -d --name "${AR_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e VAULT_ENC_KEY="${ENC_KEY}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e PACKAGE_ENFORCEMENT=1 -e PORT=3021 \
  -p "127.0.0.1:${PORT_AR_OFF}:3021" "${AR_IMG}" >/dev/null
wait_ready "${TC}" "${PORT_TC}"       || fail "tenant-control not ready (line: wait TC)"
wait_ready "${AR_ON}" "${PORT_AR_ON}"   || fail "adapter-registry-ON not ready (line: wait AR_ON)"
wait_ready "${AR_OFF}" "${PORT_AR_OFF}" || fail "adapter-registry-OFF not ready (line: wait AR_OFF)"
ok "all three services up"

# ── 3) seed tenant on essential ────────────────────────────────────────────────
step "3/8 seed tenant ${TENANT} on plan=essential via POST /v1/tenants (X-Service-Token)"
C="$(admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT}\",\"name\":\"T\",\"plan\":\"essential\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed)"
ok "tenant created on essential (tier rps=200, max_mounts=2)"

# ── 4) OPERATOR mints a custom entitlement with ceiling_plan=pro ───────────────
step "4/8 OPERATOR mints custom entitlement (ceiling_plan=pro; rps=250, aggregate=true, transactions=false, quota 5M, max_mounts:3)"
ENT_BODY='{"ceiling_plan":"pro","status":"active","entitlement":{"capabilities":{"aggregate":true,"transactions":false},"limits":{"rps":250,"burst":500,"quota.query.count":5000000},"max_mounts":3}}'
C="$(admin_req PUT "${PORT_TC}" "/v1/tenants/${TENANT}/entitlement" "${ENT_BODY}")"
[[ "${C}" == "200" ]] || fail "operator entitlement upsert expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: operator upsert)"
[[ "$(psql_val "SELECT (ceiling_plan='pro' AND status='active') FROM public.tenant_entitlements WHERE tenant_id='${TENANT}'")" == "t" ]] \
  || fail "entitlement row not stored as expected (ceiling_plan=pro, active) (line: ent row)"
ok "operator entitlement stored (ceiling_plan=pro; custom rps=250, transactions OFF)"

# ── 5) register 3 mounts of mixed engines (within custom max_mounts=3) ──────────
step "5/8 register 3 mounts (postgresql + sqlite + postgresql) within custom max_mounts=3"
ar_register "${PORT_AR_ON}" "${TENANT}" '{"engine":"postgresql","name":"m1","connection_string":"postgres://u:p@h:5432/d","isolation":"shared_rls"}' >/dev/null
M1="$(mount_id)"
ar_register "${PORT_AR_ON}" "${TENANT}" '{"engine":"sqlite","name":"m2","connection_string":"sqlite:///tmp/m2.db","isolation":"shared_rls"}' >/dev/null
M2="$(mount_id)"
ar_register "${PORT_AR_ON}" "${TENANT}" '{"engine":"postgresql","name":"m3","connection_string":"postgres://u:p@h:5432/d3","isolation":"shared_rls"}' >/dev/null
M3="$(mount_id)"
[[ -n "${M1}" && -n "${M2}" && -n "${M3}" ]] || fail "3 mounts not all registered (m1=${M1} m2=${M2} m3=${M3}) — custom max_mounts=3 (line: register 3)"
# A 4th must be REJECTED (over custom max_mounts=3).
C4="$(ar_register "${PORT_AR_ON}" "${TENANT}" '{"engine":"sqlite","name":"m4","connection_string":"sqlite:///tmp/m4.db","isolation":"shared_rls"}')"
[[ "${C4}" == "403" ]] || fail "4th mount expected 403 (custom max_mounts=3), got ${C4} — $(head -c 300 "${BODY_TMP}") (line: 4th rejected)"
ok "3 mixed-engine mounts registered; the 4th rejected 403 = custom max_mounts=3 enforced (NOT pro's 10, NOT essential's 2)"

# ── 6) THE LOAD-BEARING PROOF: /connect stamps the CUSTOM mask ─────────────────
step "6/8 LOAD-BEARING: GET /connect (BUILDER on) → capability_overrides carries the CUSTOM mask"
C="$(ar_connect "${PORT_AR_ON}" "${TENANT}" "${M1}")"
[[ "${C}" == "200" ]] || fail "/connect (ON) expected 200, got ${C} — $(head -c 400 "${BODY_TMP}") (line: connect ON)"
RPS="$(co_num rps)"; AGG="$(co_bool aggregate)"; TXN="$(co_bool transactions)"
[[ "${RPS}" == "250" ]] \
  || fail "STAMP rps=${RPS}, want 250 (the CUSTOM value — NOT essential 200, NOT pro 400). The resolver did not apply the custom entitlement! (line: stamp rps)"
[[ "${AGG}" == "true" ]] \
  || fail "STAMP aggregate=${AGG}, want true (custom) (line: stamp aggregate)"
[[ "${TXN}" == "false" ]] \
  || fail "STAMP transactions=${TXN}, want false — custom must NARROW pro's transactions:true (line: stamp transactions)"
ok "STAMP carries the CUSTOM mask: rps=250, aggregate=true, transactions=false — the builder resolver applied the per-tenant entitlement"

# ── 7) PARITY: same mount on BUILDER-OFF adapter-registry stamps the TIER mask ──
step "7/8 PARITY: GET /connect (BUILDER off) for the SAME mount → essential's tier rps=200 (NOT 250)"
C="$(ar_connect "${PORT_AR_OFF}" "${TENANT}" "${M1}")"
[[ "${C}" == "200" ]] || fail "/connect (OFF) expected 200, got ${C} — $(head -c 400 "${BODY_TMP}") (line: connect OFF)"
RPS_OFF="$(co_num rps)"
[[ "${RPS_OFF}" == "200" ]] \
  || fail "PARITY: BUILDER-off stamp rps=${RPS_OFF}, want 200 (essential tier verbatim) — the flag must be the ONLY difference (line: parity rps)"
ok "BUILDER-off stamps essential's tier rps=200 for the same mount — flag OFF = tier verbatim (byte-parity)"

# ── 8) summary + gate log ──────────────────────────────────────────────────────
step "8/8 summary"
green "[M130] LOAD-BEARING: /connect (BUILDER on) stamps the CUSTOM mask (rps=250, aggregate=true, transactions=false) — NOT essential's nor pro's tier mask"
green "[M130] max_mounts=3 (custom) enforced: 3 mixed-engine mounts OK, 4th 403"
green "[M130] PARITY: same mount on BUILDER-off stamps essential tier rps=200 — flag is the only difference"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-builder}"
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m130=PASS" --outcome pass \
      --msg "dynamic builder: a custom per-tenant entitlement (ceiling_plan=pro, rps=250, aggregate=true, transactions=false, max_mounts=3) is what /connect STAMPS as capability_overrides — NOT essential's tier (rps=200) nor pro's (rps=400); 4th mount 403 = custom max_mounts=3; BUILDER-off stamps the tier verbatim (parity)" \
      --ref "scripts/verify/m130-custom-entitlement-enforced.sh" >/dev/null 2>&1
    exit 0 ) || true
}
emit_gate_log
green "[M130] ALL GATES GREEN — the custom entitlement (not the tier) is what the data plane is stamped with"
exit 0
