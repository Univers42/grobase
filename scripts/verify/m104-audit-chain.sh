#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m104-audit-chain.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M104 — Track-D D3 TENANT-FACING TAMPER-EVIDENT AUDIT LOG gate. Proves the
# hash-chained, engine-agnostic audit trail + tenant query/export/verify API,
# and that it is byte-parity when OFF.
#
#   tenant-control (Go, TENANT_AUDIT_ENABLED=1) mounts /v1/audit* over migration
#   047's public.tenant_audit_log (per-tenant hash chain
#   hash = sha256(prev_hash || canonical(row)), computed IN GO):
#     POST /v1/audit/tenants/{id}/events   seal a link
#     GET  /v1/audit/tenants/{id}/events   query own events (seq ASC)
#     GET  /v1/audit/tenants/{id}/export   portable bundle (events + verify)
#     GET  /v1/audit/tenants/{id}/verify   recompute chain → intact / first break
#
#   (A) POSITIVE: append N events for tenant A → query returns them in seq order
#       → verify => chain INTACT → export returns the bundle (count N, verify
#       intact).
#   (B) LOAD-BEARING REJECT — TAMPER DETECTION: directly UPDATE one stored audit
#       row (mutate its payload) then call verify => it reports BROKEN at exactly
#       that link (broken_seq == the tampered seq, reason hash_mismatch). A
#       vacuous verify that always says intact FAILS here — this is the point.
#   (C) LOAD-BEARING REJECT — CROSS-TENANT: tenant B's self-credential (header
#       == B) cannot query OR verify tenant A's events (401/empty), and A's
#       header cannot reach B — isolation by construction.
#   (D) FLAG-OFF PARITY: TENANT_AUDIT_ENABLED unset → /v1/audit* → 404 (routes
#       not mounted), no audit row ever written → byte-identical to today.
#
# ISOLATED by design (mirrors m80/m87/m90): scratch postgres (047 prelude) + a
# tenant-control built FROM CURRENT source, ALL on a PRIVATE network, names
# suffixed with $$, an EXIT-trap removing EVERYTHING. It NEVER touches a
# mini-baas-* container/network/image/volume and NEVER edits docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIGRATION_047="${INFRA_DIR}/scripts/migrations/postgresql/047_tenant_audit_log.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M104] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M104] FAIL — $*"
  exit 1
}

PG_IMAGE="${M104_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m104-tc-$$:scratch"
NET="m104net-$$"
PG="m104-pg-$$"
TC_ON="m104-tc-on-$$"   # audit ENABLED
TC_OFF="m104-tc-off-$$" # parity arm (flag unset)
PORT_ON="${M104_PORT_ON:-19104}"
PORT_OFF="${M104_PORT_OFF:-19105}"
PGPW="postgres"
SVC_TOKEN="m104-internal-service-token-$$"
TENANT_A="m104-tenant-a-$$"
TENANT_B="m104-tenant-b-$$"
N_EVENTS="${M104_N_EVENTS:-4}"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# ── helpers: HTTP as the service token (admin) or as a tenant self-header ──────
# append: $1=port $2=tenant $3=auth(svc|self) $4=action $5=target $6=payload-json
append() {
  local port="$1" tenant="$2" auth="$3" action="$4" target="$5" payload="$6"
  local hdr=()
  if [[ "${auth}" == "svc" ]]; then hdr=(-H "X-Service-Token: ${SVC_TOKEN}"); else hdr=(-H "X-Baas-Tenant-Id: ${tenant}"); fi
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${port}/v1/audit/tenants/${tenant}/events" \
    -H 'Content-Type: application/json' "${hdr[@]}" \
    -d "{\"actor\":\"api-key:${auth}\",\"action\":\"${action}\",\"target\":\"${target}\",\"payload\":${payload}}"
}
# GET a sub-resource (events|export|verify) for a tenant under a chosen auth.
# $1=port $2=path-tenant $3=auth(svc|self) $4=sub  [$5=self-header-tenant override]
audit_get() {
  local port="$1" pt="$2" auth="$3" sub="$4" sh="${5:-$2}"
  local hdr=()
  if [[ "${auth}" == "svc" ]]; then hdr=(-H "X-Service-Token: ${SVC_TOKEN}"); else hdr=(-H "X-Baas-Tenant-Id: ${sh}"); fi
  curl -s -o "${BODY_TMP}" -w '%{http_code}' "${hdr[@]}" \
    "http://127.0.0.1:${port}/v1/audit/tenants/${pt}/${sub}"
}

wait_ready() { # $1=container  $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/health/live" 2>/dev/null && return 0
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

# ── 0) build the scratch tenant-control FROM CURRENT (drafted) source ──────────
step "0/9 build scratch tenant-control from CURRENT source (the D3 audit-chain code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3060 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null ||
  fail "scratch tenant-control image build failed — gate must exercise the drafted audit code"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + postgres (TCP-ready, not just socket) ─────────────────
step "1/9 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# The postgres image init runs a SOCKET-ONLY temp server then restarts — gate
# readiness on TCP (pg_isready -h 127.0.0.1) + a real SELECT 1, not the socket.
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 &&
    [[ "$(psql_val 'SELECT 1')" == "1" ]]; then break; fi
  [[ $i -eq 80 ]] && {
    docker logs "${PG}" 2>&1 | tail -20
    fail "scratch postgres never reached TCP-ready"
  }
  sleep 0.5
done
ok "postgres up + TCP-ready (SELECT 1 ok)"

# ── 1b) prelude (public.tenants + auth + roles) then the REAL migration 047 ─────
step "1b/9 prelude (public.tenants + auth + roles) then the REAL 047"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
-- Minimal public.tenants so tenant-control EnsureSchema (migration-032 check) passes.
CREATE TABLE IF NOT EXISTS public.tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug text UNIQUE, name text,
  status text DEFAULT 'active', plan text, owner_user_id text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
SQL
}
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed"
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <"${MIGRATION_047}" >/dev/null 2>&1 ||
  fail "real migration 047_tenant_audit_log.sql failed to apply"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_audit_log")" == "0" ]] || fail "tenant_audit_log should start EMPTY"
# Append-only at the grant layer: authenticated must NOT have UPDATE/DELETE.
HASUPD="$(psql_val "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='tenant_audit_log' AND grantee='authenticated' AND privilege_type IN ('UPDATE','DELETE')")" || HASUPD="?"
[[ "${HASUPD}" == "0" ]] || fail "authenticated must NOT have UPDATE/DELETE on tenant_audit_log (append-only), got ${HASUPD}"
ok "migration 047 applied — tenant_audit_log exists, empty, append-only grants for authenticated"

# ── 2) (A) boot tenant-control with the audit log ENABLED ──────────────────────
step "2/9 (A) boot tenant-control (TENANT_AUDIT_ENABLED=1)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3060 \
  -e TENANT_AUDIT_ENABLED=1 \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3060" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "ENABLED tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "tenant audit log enabled" ||
  {
    docker logs "${TC_ON}" 2>&1 | tail -20
    fail "audit log never reported enabled"
  }
ok "tenant-control up with audit API mounted (/v1/audit*)"

# ── 3) (A) POSITIVE: append N events for tenant A (mix of svc + self auth) ──────
step "3/9 (A) append ${N_EVENTS} events for ${TENANT_A} → each MUST be 201 with a sealed hash"
for n in $(seq 1 "${N_EVENTS}"); do
  AUTH="svc"
  [[ $((n % 2)) -eq 0 ]] && AUTH="self" # exercise both admin + tenant-self append
  CODE="$(append "${PORT_ON}" "${TENANT_A}" "${AUTH}" "key.issue" "key-${n}" "{\"n\":${n}}")"
  [[ "${CODE}" == "201" ]] || fail "(A) append #${n} expected 201, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
  grep -q '"hash":"' "${BODY_TMP}" || fail "(A) append #${n} body missing sealed hash — $(head -c 300 "${BODY_TMP}")"
done
DBCNT="$(psql_val "SELECT count(*) FROM public.tenant_audit_log WHERE tenant_id='${TENANT_A}'")"
[[ "${DBCNT}" == "${N_EVENTS}" ]] || fail "(A) expected ${N_EVENTS} rows for A, DB has ${DBCNT}"
# seq must be the contiguous 1..N chain (the canonical order).
MAXSEQ="$(psql_val "SELECT max(seq) FROM public.tenant_audit_log WHERE tenant_id='${TENANT_A}'")"
[[ "${MAXSEQ}" == "${N_EVENTS}" ]] || fail "(A) chain seq not contiguous (max seq=${MAXSEQ}, want ${N_EVENTS})"
GENESIS="$(psql_val "SELECT prev_hash FROM public.tenant_audit_log WHERE tenant_id='${TENANT_A}' AND seq=1")"
[[ -z "${GENESIS}" ]] || fail "(A) genesis prev_hash must be empty, got '${GENESIS}'"
ok "(A) ${N_EVENTS} events sealed; seq 1..${N_EVENTS} contiguous; genesis prev_hash empty"

# ── 4) (A) query returns them in order; verify => INTACT; export => bundle ──────
step "4/9 (A) query → in-order; verify → INTACT; export → bundle"
CODE="$(audit_get "${PORT_ON}" "${TENANT_A}" svc events)"
[[ "${CODE}" == "200" ]] || fail "(A) query events expected 200, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
QCNT="$(grep -o '"seq":[0-9]*' "${BODY_TMP}" | wc -l | tr -d ' ')"
[[ "${QCNT}" == "${N_EVENTS}" ]] || fail "(A) query returned ${QCNT} events, want ${N_EVENTS}"
# in-order: the seqs appear 1,2,3,... in the response body.
ORDER="$(grep -o '"seq":[0-9]*' "${BODY_TMP}" | sed 's/"seq"://' | tr '\n' ' ')"
EXPECT="$(seq 1 "${N_EVENTS}" | tr '\n' ' ')"
[[ "${ORDER}" == "${EXPECT}" ]] || fail "(A) query not in seq order: got [${ORDER}] want [${EXPECT}]"
ok "(A) query returns all ${N_EVENTS} events in seq order"

CODE="$(audit_get "${PORT_ON}" "${TENANT_A}" svc verify)"
[[ "${CODE}" == "200" ]] || fail "(A) verify expected 200, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
grep -q '"intact":true' "${BODY_TMP}" || fail "(A) freshly sealed chain must verify intact — $(head -c 400 "${BODY_TMP}")"
ok "(A) verify => chain INTACT"

CODE="$(audit_get "${PORT_ON}" "${TENANT_A}" svc export)"
[[ "${CODE}" == "200" ]] || fail "(A) export expected 200, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
grep -q '"format":"grobase.audit.v1"' "${BODY_TMP}" || fail "(A) export missing format tag — $(head -c 300 "${BODY_TMP}")"
grep -q "\"count\":${N_EVENTS}" "${BODY_TMP}" || fail "(A) export count != ${N_EVENTS} — $(head -c 300 "${BODY_TMP}")"
grep -q '"intact":true' "${BODY_TMP}" || fail "(A) export bundle verify not intact — $(head -c 400 "${BODY_TMP}")"
ok "(A) export => bundle (format grobase.audit.v1, count ${N_EVENTS}, verify intact)"

# ── 5) (B) LOAD-BEARING REJECT — TAMPER DETECTION ──────────────────────────────
step "5/9 (B) directly UPDATE a stored row's payload → verify MUST report BROKEN at that link"
TAMPER_SEQ=2
[[ "${N_EVENTS}" -ge 2 ]] || TAMPER_SEQ=1
# A real tamperer edits the stored row WITHOUT recomputing its hash — exactly
# what a DB-level mutation does. The chain's hash must no longer match.
psql_q >/dev/null 2>&1 <<SQL || fail "(B) could not UPDATE the audit row to tamper it"
UPDATE public.tenant_audit_log
   SET payload = '{"n":999999}'::jsonb
 WHERE tenant_id='${TENANT_A}' AND seq=${TAMPER_SEQ};
SQL
CODE="$(audit_get "${PORT_ON}" "${TENANT_A}" svc verify)"
[[ "${CODE}" == "200" ]] || fail "(B) verify after tamper expected 200 (a successful report of tampering), got ${CODE}"
grep -q '"intact":false' "${BODY_TMP}" || fail "(B) VACUOUS VERIFY REJECTED — a tampered chain reported intact:true — $(head -c 400 "${BODY_TMP}")"
grep -q "\"broken_seq\":${TAMPER_SEQ}" "${BODY_TMP}" ||
  fail "(B) verify did not pinpoint the tampered link seq=${TAMPER_SEQ} — $(head -c 400 "${BODY_TMP}")"
grep -q '"reason":"hash_mismatch"' "${BODY_TMP}" ||
  fail "(B) tamper reason should be hash_mismatch — $(head -c 400 "${BODY_TMP}")"
ok "(B) tamper DETECTED: verify => intact:false, broken_seq=${TAMPER_SEQ}, reason hash_mismatch (vacuous verify impossible)"

# ── 6) (C) LOAD-BEARING REJECT — CROSS-TENANT ──────────────────────────────────
step "6/9 (C) tenant B cannot read/verify tenant A's audit events"
# Seed one event for B so B HAS its own chain (proves B isn't just empty).
CODE="$(append "${PORT_ON}" "${TENANT_B}" self "key.issue" "b-key-1" '{"who":"b"}')"
[[ "${CODE}" == "201" ]] || fail "(C) seeding tenant B event expected 201, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
# B's self-header asking for A's path → 401 (header != path id at the edge).
CODE="$(audit_get "${PORT_ON}" "${TENANT_A}" self events "${TENANT_B}")"
[[ "${CODE}" == "401" ]] || fail "(C) B reading A's events expected 401 (cross-tenant blocked), got ${CODE} — $(head -c 200 "${BODY_TMP}")"
CODE="$(audit_get "${PORT_ON}" "${TENANT_A}" self verify "${TENANT_B}")"
[[ "${CODE}" == "401" ]] || fail "(C) B verifying A's chain expected 401, got ${CODE} — $(head -c 200 "${BODY_TMP}")"
# B reading its OWN chain works and is scoped to B only (count 1, NOT A's tampered chain).
CODE="$(audit_get "${PORT_ON}" "${TENANT_B}" self events "${TENANT_B}")"
[[ "${CODE}" == "200" ]] || fail "(C) B reading its OWN events expected 200, got ${CODE} — $(head -c 200 "${BODY_TMP}")"
BCNT="$(grep -o '"seq":[0-9]*' "${BODY_TMP}" | wc -l | tr -d ' ')"
[[ "${BCNT}" == "1" ]] || fail "(C) B's own chain should have exactly 1 event (no A bleed-through), got ${BCNT}"
grep -q '"who":"b"' "${BODY_TMP}" || fail "(C) B's own event payload not returned — $(head -c 200 "${BODY_TMP}")"
ok "(C) cross-tenant blocked: B↛A (401 read+verify); B sees ONLY its own 1-event chain"

# ── 7) (D) FLAG-OFF PARITY: TENANT_AUDIT_ENABLED unset → /v1/audit* 404 ─────────
# A flag-OFF PARITY arm must STOP/REMOVE the ENABLED container before testing OFF.
step "7/9 (D) STOP the ENABLED container, boot with TENANT_AUDIT unset (PARITY) — same DB"
docker rm -fv "${TC_ON}" >/dev/null 2>&1 || true
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3060 \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3060" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "PARITY tenant-control not ready"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "tenant audit log disabled" ||
  {
    docker logs "${TC_OFF}" 2>&1 | tail -20
    fail "OFF tenant-control did not report audit disabled (flag default not OFF?)"
  }
ROWS_BEFORE="$(psql_val "SELECT count(*) FROM public.tenant_audit_log")"
# every /v1/audit* verb → 404 (routes not mounted).
for SUB in "events" "export" "verify"; do
  CODE="$(audit_get "${PORT_OFF}" "${TENANT_A}" svc "${SUB}")"
  [[ "${CODE}" == "404" ]] || fail "(D) GET /v1/audit/.../${SUB} expected 404 with flag OFF, got ${CODE} — $(head -c 200 "${BODY_TMP}")"
done
CODE="$(append "${PORT_OFF}" "${TENANT_A}" svc "key.issue" "should-404" '{"x":1}')"
[[ "${CODE}" == "404" ]] || fail "(D) POST .../events expected 404 with flag OFF, got ${CODE} — $(head -c 200 "${BODY_TMP}")"
ROWS_AFTER="$(psql_val "SELECT count(*) FROM public.tenant_audit_log")"
[[ "${ROWS_AFTER}" == "${ROWS_BEFORE}" ]] ||
  fail "(D) flag OFF must write NO audit rows: before=${ROWS_BEFORE} after=${ROWS_AFTER}"
ok "(D) flag OFF: all /v1/audit* → 404 (unmounted), 0 rows written — byte-identical to today"

# ── 8) cross-check + summarize ─────────────────────────────────────────────────
step "8/9 cross-check arms"
green "[M104] (A) POSITIVE: append ${N_EVENTS} → query in-order → verify INTACT → export bundle"
green "[M104] (B) REJECT (tamper): UPDATE a row's payload → verify intact:false @ broken_seq=${TAMPER_SEQ} hash_mismatch"
green "[M104] (C) REJECT (cross-tenant): B↛A read+verify → 401; B sees only its own chain"
green "[M104] (D) PARITY: /v1/audit* → 404 (unmounted), 0 rows written — byte-parity baseline"

# ── 9) emit the gate event via the kernel log helper (best-effort) ─────────────
step "9/9 log GATE m104=PASS"
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d3-audit-chain}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m104=PASS" --outcome pass \
      --msg "D3 tamper-evident audit: append/query/verify(INTACT)/export; tampered row → verify intact:false @ exact broken_seq hash_mismatch; cross-tenant B↛A 401; flag OFF → 404 (unmounted, 0 rows, byte-parity)" \
      --ref "scripts/verify/m104-audit-chain.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M104] ALL GATES GREEN — tamper-evident audit chain proves intact, DETECTS tampering at the exact link, blocks cross-tenant, and is byte-parity when OFF"
exit 0
