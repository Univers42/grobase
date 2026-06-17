#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m120-spend-suspend-enforce.sh                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M120 — data-plane SPEND-CAP + ABUSE-SUSPEND enforcement on the request path.
# The data plane already honors the B2 quota:over set (gate m101); this gate
# proves it ALSO honors two MORE control-plane Redis honor sets it must consume:
#
#   spend:over        → request rejected with 402, body error "spend_capped"
#   tenant:suspended  → request rejected with 403, body error "tenant_suspended"
#
# UNLIKE m101 this needs NO Go orchestrator / tenant-control / QuotaGuard: the
# two honor sets are seeded DIRECTLY into a scratch Redis via SADD, exactly as a
# real spend-cap / abuse guard would publish them. A scratch postgres + a bare
# probe table is included ONLY to give the served (200) control a REAL data path
# (the router lists a real row) — without it a "200 control" would be a fiction.
#
#   (A) ENFORCE arm (DATA_PLANE_SPEND_CAPS=1 + DATA_PLANE_SUSPEND_READER=1 +
#       METERING_ENABLED=1):
#         · spend-over tenant  → 402, body contains "spend_capped"   (LOAD-BEARING)
#         · suspended tenant   → 403, body contains "tenant_suspended"(LOAD-BEARING)
#         · normal tenant (in NEITHER set) → 200 (real served read — the control)
#   (B) PARITY arm (both flags UNSET): the SAME spend-over AND suspended tenants
#       BOTH return 200 — the new sets are NEVER consulted = byte-parity.
#
# NON-VACUOUS by construction: on today's HEAD (no spend/suspend reader in the
# data plane) the spend-over and suspended tenants would be served (200), so the
# 402/403 expectations in arm (A) get 200 → the gate FAILS. It PASSES only once
# the S1 code lands. Distinct status codes (402 vs 403) and distinct source sets
# (spend:over vs tenant:suspended — NEITHER is quota:over) keep it from passing on
# the pre-existing quota path.
#
# ISOLATED by design (mirrors m101): scratch redis + postgres + a data-plane-
# router built FROM CURRENT source, on a PRIVATE network, every name suffixed $$,
# an EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-* container/
# network/image/volume and NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
DPR_DIR="${INFRA_DIR}/docker/services/data-plane-router"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M120] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M120] FAIL — $*"; exit 1; }

REDIS_IMAGE="${M120_REDIS_IMAGE:-redis:7-alpine}"
PG_IMAGE="${M120_PG_IMAGE:-postgres:16-alpine}"
DPR_IMG="m120-dpr-$$:scratch"
NET="m120net-$$"
PG="m120-pg-$$"
REDIS="m120-redis-$$"
DPR_ON="m120-dpr-on-$$"     # (A) ENFORCE arm router
DPR_OFF="m120-dpr-off-$$"   # (B) PARITY  arm router
PORT_ON="${M120_PORT_ON:-18992}"
PORT_OFF="${M120_PORT_OFF:-18993}"
PGPW="postgres"

# Three DISTINCT tenant slugs: one for each honor set + one normal control.
SLUG_SPEND="t-spend-over-$$"        # seeded into spend:over       → expect 402
SLUG_SUSPENDED="t-suspended-$$"     # seeded into tenant:suspended → expect 403
SLUG_NORMAL="t-normal-$$"           # in NEITHER set               → expect 200
PROBE_TABLE="m120_probe"
REFRESH_MS="${M120_REFRESH_MS:-700}"     # LOW so the data plane refreshes fast
REDIS_INNET="redis://${REDIS}:6379"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR_ON}" "${DPR_OFF}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${DPR_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli() { docker exec -i "${REDIS}" redis-cli "$@"; }

# Build the /v1/query envelope for a `list` against the bare probe table, as a
# given tenant identity. identity.tenant_id is the SLUG — what the honor sets key
# on (SADD <set> <slug>). The mount carries an inline DSN so no adapter-registry
# is needed; isolation shared_rls but the probe table is bare (no RLS) so a real
# read returns its one row → a genuine 200 control.
#   $1 = tenant slug
payload_list() {
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m120","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"list","resource":"%s","data":null}}' \
    "$1" "$1" "$1" "${DB_INNET}" "${PROBE_TABLE}"
}

post_q() { # $1=port  $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
}

wait_ready() { # $1=container  $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/v1/capabilities" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
}

# ── 0) build the scratch DPR FROM CURRENT (drafted) source (the S1 code) ───────
step "0/6 build scratch data-plane-router from CURRENT source (the spend/suspend honor code)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch data-plane-router image build failed (line: docker build DPR)"
ok "scratch image built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis + postgres ─────────────────────────────────────
step "1/6 boot isolated net (${NET}): redis + postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 60); do redis_cli PING 2>/dev/null | grep -q PONG && break; [[ $i -eq 60 ]] && fail "scratch redis never PONGed (line: redis ready)"; sleep 0.5; done
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
ok "redis + postgres up"

# ── 2) seed: the bare probe table (one row) + the two honor sets directly ───────
step "2/6 seed bare probe table (one row → real 200 control) + SADD spend:over / tenant:suspended"
seed_pg() {
  psql_q >/dev/null 2>&1 <<SQL
-- A bare (no-RLS) table the data plane lists; one row so a served read returns 200.
CREATE TABLE IF NOT EXISTS public.${PROBE_TABLE} (id text PRIMARY KEY, label text);
INSERT INTO public.${PROBE_TABLE}(id, label) VALUES ('p1','ok') ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed_pg && break; [[ $i -eq 20 ]] && fail "probe-table seed never committed (line: seed_pg loop)"; sleep 0.5; done
[[ "$(psql_val "SELECT count(*) FROM public.${PROBE_TABLE}")" == "1" ]] \
  || fail "probe table must hold exactly one row for a real 200 control (line: probe row check)"

# Seed the two honor sets DIRECTLY — what a real spend-cap / abuse guard publishes.
# NEITHER is quota:over (the pre-existing B2 path), so a pass here cannot be the
# quota machinery in disguise.
redis_cli SADD spend:over "${SLUG_SPEND}" >/dev/null \
  || fail "SADD spend:over failed (line: seed spend:over)"
redis_cli SADD tenant:suspended "${SLUG_SUSPENDED}" >/dev/null \
  || fail "SADD tenant:suspended failed (line: seed tenant:suspended)"
# Prove the sets are EXACTLY as intended and the normal tenant is in NEITHER.
[[ "$(redis_cli SISMEMBER spend:over "${SLUG_SPEND}")" == "1" ]]        || fail "spend:over missing the spend slug (line: verify spend member)"
[[ "$(redis_cli SISMEMBER tenant:suspended "${SLUG_SUSPENDED}")" == "1" ]] || fail "tenant:suspended missing the suspended slug (line: verify suspend member)"
[[ "$(redis_cli SISMEMBER spend:over "${SLUG_NORMAL}")" == "0" ]]        || fail "normal slug wrongly in spend:over (line: normal not in spend)"
[[ "$(redis_cli SISMEMBER tenant:suspended "${SLUG_NORMAL}")" == "0" ]]  || fail "normal slug wrongly in tenant:suspended (line: normal not in suspend)"
# quota:over stays EMPTY — this gate exercises ONLY the two new sets.
[[ "$(redis_cli SCARD quota:over)" == "0" ]] || fail "quota:over should be empty — m120 tests the NEW sets, not B2 quota (line: quota:over empty)"
ok "seeded: probe row(1); spend:over={${SLUG_SPEND}}; tenant:suspended={${SLUG_SUSPENDED}}; normal in neither; quota:over empty"

# ── 3) (A) ENFORCE arm: both honor flags ON ────────────────────────────────────
step "3/6 boot data-plane-router DATA_PLANE_SPEND_CAPS=1 + DATA_PLANE_SUSPEND_READER=1 (A · ENFORCE), refresh=${REFRESH_MS}ms"
docker run -d --name "${DPR_ON}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e METERING_ENABLED=1 \
  -e DATA_PLANE_SPEND_CAPS=1 \
  -e DATA_PLANE_SUSPEND_READER=1 \
  -e DATA_PLANE_QUOTA_REFRESH_MS="${REFRESH_MS}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_ON}:4011" "${DPR_IMG}" >/dev/null
wait_ready "${DPR_ON}" "${PORT_ON}" || fail "ENFORCE router not ready (line: wait_ready DPR_ON)"
sleep "$(awk "BEGIN{print (${REFRESH_MS}*2/1000)+1}")"
ok "ENFORCE router up (both honor sets refreshing from redis) on 127.0.0.1:${PORT_ON}"

step "3b/6 (A) spend-over tenant → MUST be 402 body spend_capped (LOAD-BEARING)"
CODE_SPEND=
for i in $(seq 1 20); do
  CODE_SPEND="$(post_q "${PORT_ON}" "$(payload_list "${SLUG_SPEND}")")"
  [[ "${CODE_SPEND}" == "402" ]] && break
  sleep 0.5
done
[[ "${CODE_SPEND}" == "402" ]] \
  || fail "(A) spend-over expected 402, got ${CODE_SPEND} — $(head -c 300 "${BODY_TMP}") (line: A spend 402)"
grep -q 'spend_capped' "${BODY_TMP}" \
  || fail "(A) 402 body missing spend_capped — $(head -c 300 "${BODY_TMP}") (line: A spend body)"
ok "(A) spend-over tenant rejected 402 spend_capped — spend-cap enforcement is REAL"

step "3c/6 (A) suspended tenant → MUST be 403 body tenant_suspended (LOAD-BEARING)"
CODE_SUSP=
for i in $(seq 1 20); do
  CODE_SUSP="$(post_q "${PORT_ON}" "$(payload_list "${SLUG_SUSPENDED}")")"
  [[ "${CODE_SUSP}" == "403" ]] && break
  sleep 0.5
done
[[ "${CODE_SUSP}" == "403" ]] \
  || fail "(A) suspended expected 403, got ${CODE_SUSP} — $(head -c 300 "${BODY_TMP}") (line: A suspend 403)"
grep -q 'tenant_suspended' "${BODY_TMP}" \
  || fail "(A) 403 body missing tenant_suspended — $(head -c 300 "${BODY_TMP}") (line: A suspend body)"
ok "(A) suspended tenant rejected 403 tenant_suspended — abuse-suspend enforcement is REAL"

step "3d/6 (A) normal tenant (in neither set) → MUST be 200 (real served read = the control)"
CODE_NORMAL="$(post_q "${PORT_ON}" "$(payload_list "${SLUG_NORMAL}")")"
[[ "${CODE_NORMAL}" == "200" ]] \
  || fail "(A) normal tenant expected 200, got ${CODE_NORMAL} — $(head -c 300 "${BODY_TMP}") (line: A normal 200)"
ok "(A) normal tenant served 200 — enforcement does NOT over-reject; the 200 control is REAL"

# ── 4) (B) PARITY arm: both honor flags UNSET → all 200 ────────────────────────
step "4/6 boot data-plane-router with both honor flags UNSET (B · PARITY) — same redis, same seeds"
docker run -d --name "${DPR_OFF}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_OFF}:4011" "${DPR_IMG}" >/dev/null
wait_ready "${DPR_OFF}" "${PORT_OFF}" || fail "PARITY router not ready (line: wait_ready DPR_OFF)"
ok "PARITY router up (both honor flags OFF) on 127.0.0.1:${PORT_OFF}"

step "4b/6 (B) spend-over tenant through the OFF router → MUST be 200 (flag OFF = byte-parity)"
PCODE_SPEND="$(post_q "${PORT_OFF}" "$(payload_list "${SLUG_SPEND}")")"
[[ "${PCODE_SPEND}" == "200" ]] \
  || fail "(B) PARITY spend-over expected 200 (flag OFF), got ${PCODE_SPEND} — $(head -c 300 "${BODY_TMP}") (line: B spend 200)"
ok "(B) spend-over tenant served 200 with flags OFF — spend:over is NOT consulted"

step "4c/6 (B) suspended tenant through the OFF router → MUST be 200 (flag OFF = byte-parity)"
PCODE_SUSP="$(post_q "${PORT_OFF}" "$(payload_list "${SLUG_SUSPENDED}")")"
[[ "${PCODE_SUSP}" == "200" ]] \
  || fail "(B) PARITY suspended expected 200 (flag OFF), got ${PCODE_SUSP} — $(head -c 300 "${BODY_TMP}") (line: B suspend 200)"
ok "(B) suspended tenant served 200 with flags OFF — tenant:suspended is NOT consulted = byte-parity"

# ── 5) cross-check + summarize ─────────────────────────────────────────────────
step "5/6 cross-check: ON rejects spend-over(402 spend_capped)/suspended(403 tenant_suspended)/serves normal(200); OFF serves ALL(200)"
green "[M120] (A) ENFORCE: spend-over→402 spend_capped · suspended→403 tenant_suspended · normal→200"
green "[M120] (B) PARITY:  spend-over→200 · suspended→200 · normal→200            (both flags OFF → byte-parity)"
green "[M120] non-vacuous: on today's HEAD (no spend/suspend reader) arm (A) would serve both (200) and FAIL."

# ── 6) emit the gate event via the kernel log helper (best-effort) ─────────────
step "6/6 log GATE m120=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-s1-spend-suspend-enforce}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m120=PASS" --outcome pass \
      --msg "data-plane honors spend:over (402 spend_capped) + tenant:suspended (403 tenant_suspended) seeded directly in redis; normal tenant 200 (real served read); both flags OFF → all 200 (byte-parity). Mirrors B2 quota honor machinery; fail-OPEN identical. Non-vacuous: fails today's HEAD." \
      --ref "scripts/verify/m120-spend-suspend-enforce.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M120] ALL GATES GREEN — spend-cap (402 spend_capped) + abuse-suspend (403 tenant_suspended) honored on the data path; flag-OFF byte-parity"
exit 0
